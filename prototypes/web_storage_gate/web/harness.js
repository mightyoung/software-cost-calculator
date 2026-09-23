// NONPRODUCT: isolated test identities; never points at application data.
const run = new URLSearchParams(location.search).get('run') || 'manual';
const metaName = 'nonproduct-t1-meta-' + run;
const lockName = 'nonproduct-t1-write-' + run;
const check = (v, m) => { if (!v) throw Error(m); };
async function meta(value, abort = false) {
  const db = await new Promise((resolve, reject) => {
    const r = indexedDB.open(metaName, 1);
    r.onupgradeneeded = () => r.result.createObjectStore('pointer');
    r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error);
  });
  try { return await new Promise((resolve, reject) => {
    const t = db.transaction('pointer', value ? 'readwrite' : 'readonly');
    const s = t.objectStore('pointer'); const r = value ? s.put(value, 'active') : s.get('active');
    t.oncomplete = () => resolve(r.result); t.onerror = () => { if (!abort) reject(t.error); };
    t.onabort = () => abort ? resolve('aborted') : reject(t.error);
    if (abort) t.abort();
  }); } finally { db.close(); }
}
async function commit(expected) {
  return navigator.locks.request(lockName, async () => {
    const active = await meta();
    if (JSON.stringify(active) !== JSON.stringify(expected)) throw Error('STALE_EPOCH');
    window.commitSQLStarted = true;
    return await probeCommit(); // Application lock -> metadata check -> SQL transaction.
  });
}
async function loadPeer() {
  // A separate top-level browsing context, not a frame. The runner confirms CDP targets.
  const peer = window.open('?run=' + encodeURIComponent(run) + '&peer=1', '_blank');
  check(peer, 'top-level peer popup blocked');
  window.peerWindow = peer;
  await new Promise((resolve, reject) => {
    const start = Date.now(); const timer = setInterval(() => {
      if (peer.probeReady) { clearInterval(timer); resolve(); }
      else if(Date.now()-start>20000) {clearInterval(timer);reject(Error('peer timeout'));}
    }, 25);
  });
  check(peer.top === peer && peer !== window, 'peer must be a separate top-level page');
  return peer;
}
window.runTests = async () => {
  check(window.probeReady, 'Dart not ready');
  window.stage="seed"; await probeSeed(); const usageBefore=await navigator.storage.estimate(); const old = {instance:'old', epoch:1}; await meta(old);
  window.stage="peer"; const peer = await loadPeer();
  const root = await navigator.storage.getDirectory();
  const file = await root.getFileHandle('nonproduct-t1-export-' + run, {create:true});
  const stream = await file.createWritable(); let writer, settled = false, pages=0;
  window.probePage = async page => { pages++; await stream.write(page); };
  window.probeInterleave = async () => {
    writer = peer.commit(old).then(() => {settled=true;});
    await new Promise(r=>setTimeout(r,250));
    check(peer.commitSQLStarted, 'competing writer did not reach SQL');
    check(!settled, 'writer must wait while explicit read transaction owns database');
  };
  window.stage="snapshot"; const snapshot = JSON.parse(await probeSnapshot()); await stream.close(); await writer;
  check(snapshot.generation===1 && snapshot.rows===1025 && snapshot.maxPage===64, 'snapshot bound/generation');
  check(pages===17 && snapshot.allOriginal, 'snapshot mixed generations');
  const after = JSON.parse(await probeState()); check(after.generation===2 && after.changed===1025,'writer completion');
  window.stage="lock"; let lockBlocked;
  await navigator.locks.request(lockName, async()=>{
    lockBlocked=await peer.navigator.locks.request(lockName,{ifAvailable:true},l=>l===null);
  }); check(lockBlocked,'cross-context application lock');
  window.stage="two-writers";
  let queuedWriter, queuedFinished=false, writerBlocked;
  await navigator.locks.request(lockName, async()=>{
    check((await meta()).epoch===1, 'main writer epoch');
    peer.commitSQLStarted=false;
    queuedWriter=peer.commit(old).then(()=>{queuedFinished=true;});
    await new Promise(r=>setTimeout(r,100));
    writerBlocked=!peer.commitSQLStarted && !queuedFinished;
    check(writerBlocked, 'peer writer bypassed main writer application lock');
    await probeCommit(); // Main-page write transaction under the application lock.
  });
  await queuedWriter;
  const afterTwoWriters=JSON.parse(await probeState());
  check(afterTwoWriters.generation===4, 'two writers must each commit exactly once');
  await navigator.locks.request(lockName,async()=>{
    window.stage="abort"; await meta({instance:'new',epoch:2},true); check((await meta()).epoch===1,'aborted pointer changed');
    window.stage="switch"; await meta({instance:'new',epoch:2});
  });
  let fenced=false; try { await peer.commit(old); } catch(e) {fenced=String(e).includes('STALE_EPOCH');}
  check(fenced,'old connection not fenced');
  check((JSON.parse(await probeState())).generation===4,'fenced SQL wrote');
  const result={status:'PASS',scope:'NONPRODUCT two top-level pages',snapshot,after,lockBlocked,fenced,writerBlocked,afterTwoWriters,
    bytes:(await file.getFile()).size,usageBefore,usageAfter:await navigator.storage.estimate(),storage:JSON.parse(window.probeInfo),userAgent:navigator.userAgent};
  localStorage.setItem('nonproduct-t1-result-'+run,JSON.stringify(result));
  document.querySelector('#output').textContent=JSON.stringify(result,null,2); return result;
};
window.checkReload = async(expectedGeneration=4)=>{
  const previous=JSON.parse(localStorage.getItem('nonproduct-t1-result-'+run));
  check(previous?.status==='PASS','missing prior run');
  const state=JSON.parse(await probeState()); check(state.generation===expectedGeneration && state.changed===1025,'SQL reopen persistence');
  check((await meta()).epoch===2,'pointer reload persistence');
  return {status:'PASS',state,pointer:await meta(),storage:JSON.parse(probeInfo)};
};

// Crash injection is inside a real, uncommitted SQL write transaction.
window.probeCrashBarrier = async () => {
  window.crashBarrierReached = true;
  await new Promise(() => {});
};
window.beginCrashWrite = async () => navigator.locks.request(lockName, async () => {
  check((await meta()).epoch===2, 'unexpected epoch before crash injection');
  return await probeHoldCommit();
});
