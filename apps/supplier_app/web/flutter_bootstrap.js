{{flutter_js}}
{{flutter_build_config}}

// SUPPLIER_OFFLINE_BOOTSTRAP
(() => {
  'use strict';
  const release = '__SUPPLIER_RELEASE__';
  const fail = error => {
    console.error('Offline resource preparation failed', error);
    const message = document.createElement('p');
    message.textContent = '应用资源未准备完成，请联网后重新打开。现有本地数据未被修改。';
    document.body.replaceChildren(message);
  };
  const workerRelease = worker => new Promise((resolve, reject) => {
    const channel = new MessageChannel();
    const timer = setTimeout(() => { channel.port1.close(); reject(Error('Resource version handshake timed out')); }, 10000);
    channel.port1.onmessage = event => {
      clearTimeout(timer);
      channel.port1.close();
      resolve(event.data?.release);
    };
    worker.postMessage({type: 'supplier-release'}, [channel.port2]);
  });
  const script = url => new Promise((resolve, reject) => {
    const node = document.createElement('script');
    node.src = url;
    node.onload = resolve;
    node.onerror = () => reject(Error('Platform resource could not be loaded'));
    document.head.append(node);
  });
  (async () => {
    if (release.startsWith('__SUPPLIER_')) throw Error('Run tool/build_web_offline.py before deployment');
    if (!navigator.serviceWorker) throw Error('A secure origin with service workers is required');
    const registration = await navigator.serviceWorker.register('supplier_offline_sw.js', {updateViaCache: 'none'});
    // Do not force waiting updates onto an open page. First installation waits
    // for an active worker, then reloads before starting the application.
    if (!navigator.serviceWorker.controller) {
      await Promise.race([
        navigator.serviceWorker.ready,
        new Promise((_, reject) => {
          const installing = registration.installing;
          if (!installing) return;
          const check = () => { if (installing.state === 'redundant') reject(Error('Offline resources failed verification')); };
          installing.addEventListener('statechange', check);
          check();
        }),
        new Promise((_, reject) => setTimeout(() => reject(Error('Offline cache installation timed out')), 120000)),
      ]);
      location.reload();
      return;
    }
    if (await workerRelease(navigator.serviceWorker.controller) !== release) {
      throw Error('Application and cached resource versions differ');
    }
    await script('supplier_platform.js');
    await _flutter.loader.load({config: {canvasKitBaseUrl: 'canvaskit/', fontFallbackBaseUrl: 'fonts/'}});
    // update() may fail offline; the fully cached active release stays usable.
    registration.update().catch(() => {});
  })().catch(fail);
})();
