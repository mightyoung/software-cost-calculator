// NONPRODUCT fixture protocol. All helpers execute under the one caller-owned lock.
let heldRestoreContext = null;
function validCandidate(f) {
  return f.instance==='candidate' && f.generation===42 && f.rows===17 &&
    f.validRows===17 && f.minId===1 && f.maxId===17 && f.integrity==='ok';
}
const samePointer = (a,b) => a.instance===b.instance && a.epoch===b.epoch;
async function withRestoreLock(body) {
  return navigator.locks.request(lockName, async()=>{
    const context = {}; heldRestoreContext = context;
    try {return await body(context);} finally {heldRestoreContext=null;}
  });
}
function requireHeld(context) { check(context && context===heldRestoreContext,'missing held lock context'); }
window.restoreReadPointer = async () => {
  const existing = await meta();
  window.restorePointerExists = Boolean(existing);
  const pointer = existing || {instance:'old',epoch:1};
  window.boundPointer = Object.freeze({...pointer});
  return JSON.stringify(pointer);
};
window.restoreInit = async () => withRestoreLock(async context=>{
  requireHeld(context);
  await meta({instance:'old',epoch:1});
  await restoreSeedOld();
  const candidate=JSON.parse(await restorePrepareCandidate());
  check(validCandidate(candidate),'candidate incomplete');
  window.restoreWriteEnabled=true;
  return {old:JSON.parse(await restoreFacts()),candidate};
});
async function switchPointerHeld(context, next, pauseInside, barrier='inside-pointer') {
  requireHeld(context);
  if (!pauseInside) return meta(next);
  const db=await new Promise((resolve,reject)=>{
    const r=indexedDB.open(metaName,1); r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);
  });
  return new Promise((resolve,reject)=>{
    const txn=db.transaction('pointer','readwrite'); const store=txn.objectStore('pointer');
    txn.oncomplete=()=>{db.close();resolve();}; txn.onerror=()=>{db.close();reject(txn.error);};
    txn.onabort=()=>{db.close();reject(txn.error);};
    const put=store.put(next,'active');
    put.onsuccess=()=>{
      window.restoreBarrier=barrier; window.pointerTxnTicks=0;
      // Keep a real IDB write transaction alive with pending requests until process kill.
      const keepAlive=()=>{const r=store.get('active');r.onsuccess=()=>{window.pointerTxnTicks++;keepAlive();};};
      keepAlive();
    };
  });
}
async function pauseAt(point, actual) {
  if(point===actual) {window.restoreBarrier=point;await new Promise(()=>{});}
}
window.activateRestore = async(point='none') => withRestoreLock(async context=>{
  requireHeld(context);
  check(samePointer(await meta(),{instance:'old',epoch:1}),'activation token stale');
  const candidate=JSON.parse(await restoreInspectCandidate());
  check(validCandidate(candidate),'candidate validation failed');
  await restoreClose();
  await pauseAt(point,'before-pointer');
  await switchPointerHeld(context,{instance:'candidate',epoch:2},point==='inside-pointer');
  await pauseAt(point,'after-pointer');
  // Reuse the lock context; opening SQL never waits to reacquire the application lock.
  requireHeld(context); await restoreReopen();
  const active=JSON.parse(await restoreFacts());
  check(validCandidate(active),'activated fixture invalid');
  window.restoreWriteEnabled=true;
  return active;
});
window.restoreWrite = async()=>withRestoreLock(async context=>{
  requireHeld(context);
  check(window.restoreWriteEnabled,'REOPEN_VALIDATION_REQUIRED');
  check(samePointer(await meta(),window.boundPointer),'STALE_EPOCH');
  await restoreSqlWrite();
  return JSON.parse(await restoreFacts());
});
function validOld(f) {
  return f.instance==='old' && f.generation===1 && f.rows===1025 &&
    f.validRows===1025 && f.minId===1 && f.maxId===1025 && f.integrity==='ok';
}
async function rollbackHeld(context, point='none') {
  requireHeld(context);
  const pointer=await meta();
  check(samePointer(pointer,{instance:'candidate',epoch:2}),'rollback token stale');
  const active=JSON.parse(await restoreFacts());
  check(active.instance==='candidate' && active.generation===42,'NEW_WRITES_PREVENT_ROLLBACK');
  await restoreClose();
  await switchPointerHeld(context,{instance:'old',epoch:pointer.epoch+1},
    point==='rollback-inside-pointer','rollback-inside-pointer');
  await pauseAt(point,'rollback-after-pointer');
  await restoreReopen();
  const old=JSON.parse(await restoreFacts());
  check(validOld(old),'rollback fixture invalid');
  window.restoreWriteEnabled=true;
  return old;
}
window.attemptAutomaticRollback = async()=>withRestoreLock(context=>rollbackHeld(context));
window.checkRestored = async()=>{
  const pointer=await meta(); const facts=JSON.parse(await restoreFacts());
  check(samePointer(pointer,window.boundPointer),'connection not bound to active pointer');
  check(pointer.instance===facts.instance && facts.integrity==='ok','active identity/integrity mismatch');
  const expected=pointer.instance==='old'?1025:17;
  check(facts.rows===expected && facts.validRows===expected && facts.minId===1 && facts.maxId===expected,'incomplete restored fixture');
  return {pointer,boundPointer:window.boundPointer,facts,storage:JSON.parse(probeInfo)};
};
window.restoreSuccessTests = async()=>{
  const peer=await loadPeer();
  const active=await activateRestore();
  let fenced=false;try{await peer.restoreWrite();}catch(e){fenced=String(e).includes('STALE_EPOCH');}
  check(fenced,'old top-level connection wrote after switch');
  const oldUnchanged=JSON.parse(await peer.restoreFacts());
  check(oldUnchanged.instance==='old'&&oldUnchanged.generation===1&&oldUnchanged.validRows===1025,'old database mutated');
  const written=await restoreWrite(); check(written.generation===43,'new write missing');
  let rollbackDenied=false;try{await attemptAutomaticRollback();}catch(e){rollbackDenied=String(e).includes('NEW_WRITES_PREVENT_ROLLBACK');}
  check(rollbackDenied,'automatic rollback discarded accepted writes');
  return {active,fenced,oldUnchanged,written,rollbackDenied,final:await checkRestored()};
};

// Negative fixture: real SQL retains count/content but shifts primary keys from 1..17 to 2..18.
window.restoreWrongRangeTests = async()=>{
  await withRestoreLock(async context=>{requireHeld(context);await restoreShiftCandidateIds();});
  const invalid=JSON.parse(await restoreInspectCandidate());
  check(invalid.rows===17 && invalid.validRows===17 && invalid.minId===2 && invalid.maxId===18,'negative fixture not installed');
  let activationRejected=false;
  try{await activateRestore();}catch(e){activationRejected=String(e).includes('candidate validation failed');}
  check(activationRejected,'wrong-range candidate activated');
  const preserved=await checkRestored();
  check(preserved.pointer.instance==='old' && preserved.facts.generation===1,'failed activation altered active database');
  // Force the invalid pointer only as fault injection to exercise real reopen validation.
  let reopenRejected=false, reopenError;
  await withRestoreLock(async context=>{
    await restoreClose();
    await switchPointerHeld(context,{instance:'candidate',epoch:2},false);
    try{await restoreReopen();}catch(e){reopenError=String(e);reopenRejected=true;}
  });
  check(reopenRejected && !window.restoreWriteEnabled,'wrong-range reopen failed assertion: '+JSON.stringify({reopenRejected,reopenError,writeEnabled:window.restoreWriteEnabled}));
  let writeRejected=false;
  try{await restoreWrite();}catch(e){writeRejected=String(e).includes('REOPEN_VALIDATION_REQUIRED');}
  check(writeRejected,'write allowed after invalid reopen');
  return {invalid,activationRejected,preserved,reopenRejected,reopenError,writeRejected,writeEnabled:window.restoreWriteEnabled};
};

// Failure is injected after committing the candidate pointer, before accepting any writes.
window.restoreFailureRollbackTests = async(point='none')=>{
  const oldPeer=await loadPeer();
  let candidatePeer;
  const result=await withRestoreLock(async context=>{
    check(samePointer(await meta(),{instance:'old',epoch:1}),'failure test initial pointer');
    check(validCandidate(JSON.parse(await restoreInspectCandidate())),'failure test candidate');
    await restoreClose();
    await switchPointerHeld(context,{instance:'candidate',epoch:2},false);
    candidatePeer=await loadPeer(); // Bound to epoch 2 before fault injection, while writer lock is held.
    check(samePointer(candidatePeer.boundPointer,{instance:'candidate',epoch:2}),'candidate peer epoch');
    await restoreShiftCandidateIds();
    let reopenRejected=false;
    try{await restoreReopen();}catch(_){reopenRejected=true;}
    const failed=JSON.parse(await restoreFacts());
    check(reopenRejected && !window.restoreWriteEnabled && failed.generation===42 &&
      failed.rows===17 && failed.minId===2 && failed.maxId===18,'post-switch failure not detected');
    window.rollbackFailureEvidence={reopenRejected,writeEnabled:window.restoreWriteEnabled,failed};
    const restored=await rollbackHeld(context,point);
    return {failure:window.rollbackFailureEvidence,restored};
  });
  async function stale(peer) {
    try{await peer.restoreWrite();return false;}catch(e){return String(e).includes('STALE_EPOCH');}
  }
  result.oldEpochFenced=await stale(oldPeer);
  result.candidateEpochFenced=await stale(candidatePeer);
  check(result.oldEpochFenced && result.candidateEpochFenced,'rollback did not fence both older epochs');
  result.current=await checkRestored();
  check(result.current.pointer.epoch===3,'rollback epoch must advance');
  return result;
};
window.checkRollbackRecovery = async()=>{
  const pointer=await meta(), state=JSON.parse(await restoreFacts());
  check(samePointer(pointer,window.boundPointer),'rollback recovery pointer binding');
  if(pointer.instance==='old') {
    check(pointer.epoch===3 && validOld(state) && window.restoreWriteEnabled,'old rollback recovery incomplete');
  } else {
    check(pointer.instance==='candidate' && pointer.epoch===2 && state.instance==='candidate' &&
      state.generation===42 && state.rows===17 && state.validRows===17 && state.minId===2 &&
      state.maxId===18 && state.integrity==='ok' && !window.restoreWriteEnabled &&
      Boolean(window.restoreValidationError),'failed candidate exposed writes');
    let rejected=false;
    try{await restoreWrite();}catch(e){rejected=String(e).includes('REOPEN_VALIDATION_REQUIRED');}
    check(rejected,'failed candidate writes not blocked after restart');
  }
  return {pointer,state,writeEnabled:window.restoreWriteEnabled,validationError:window.restoreValidationError};
};
