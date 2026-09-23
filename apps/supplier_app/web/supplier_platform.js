// Browser APIs used by the Dart platform ports. Business rules stay in core.
(() => {
  'use strict';
  const validName = value => {
    if (typeof value !== 'string' || !/^[a-zA-Z0-9_-]{1,120}$/.test(value)) {
      throw new Error('Invalid private storage namespace');
    }
    return value;
  };
  const same = (a, b) => {
    if (a === b) return true;
    if (!a || !b || typeof a !== 'object' || typeof b !== 'object') return false;
    const keys = Object.keys(a).sort(), other = Object.keys(b).sort();
    return keys.length === other.length && keys.every((key, i) => key === other[i] && same(a[key], b[key]));
  };
  async function openMetadata(namespace) {
    validName(namespace);
    return new Promise((resolve, reject) => {
      let blocked = false;
      const request = indexedDB.open(`supplier-${namespace}-installation`, 1);
      request.onupgradeneeded = () => request.result.createObjectStore('records');
      request.onsuccess = () => {
        if (blocked) request.result.close(); else resolve(request.result);
      };
      request.onerror = () => reject(request.error);
      request.onblocked = () => {
        blocked = true;
        reject(new Error('Installation metadata upgrade is blocked by another tab'));
      };
    });
  }
  async function readMetadata(namespace, key) {
    const db = await openMetadata(namespace);
    try {
      return await new Promise((resolve, reject) => {
        const transaction = db.transaction('records', 'readonly');
        const request = transaction.objectStore('records').get(key);
        transaction.oncomplete = () => resolve(JSON.stringify(request.result ?? null));
        transaction.onabort = () => reject(transaction.error ?? new Error('Metadata read aborted'));
        transaction.onerror = () => {}; // onabort owns the single terminal result.
      });
    } finally { db.close(); }
  }
  async function compareAndSetMetadata(namespace, expectedJson, changesJson) {
    const expected = JSON.parse(expectedJson), changes = JSON.parse(changesJson);
    const keys = Object.keys(expected);
    if (keys.length > 16 || Object.keys(changes).length > 16) throw new Error('Metadata batch exceeds limit');
    const db = await openMetadata(namespace);
    try {
      return await new Promise((resolve, reject) => {
        const transaction = db.transaction('records', 'readwrite', {durability: 'strict'});
        const store = transaction.objectStore('records');
        let remaining = keys.length, failure;
        const apply = () => {
          for (const [key, value] of Object.entries(changes)) {
            if (value === null) store.delete(key); else store.put(value, key);
          }
        };
        transaction.oncomplete = () => resolve();
        transaction.onabort = () => reject(failure ?? transaction.error ?? new Error('Metadata write aborted'));
        transaction.onerror = () => {};
        if (transaction.durability !== 'strict') {
          failure = new Error('Strict metadata durability is unavailable');
          transaction.abort();
          return;
        }
        if (!remaining) apply();
        for (const key of keys) {
          const request = store.get(key);
          request.onsuccess = () => {
            if (!same(request.result ?? null, expected[key])) {
              failure = new Error(`Stale installation metadata: ${key}`);
              transaction.abort();
            } else if (--remaining === 0) apply();
          };
        }
      });
    } finally { db.close(); }
  }
  function source(file) {
    return Object.freeze({
      name: file.name,
      size: file.size,
      async read(start, end) {
        if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start || end > file.size || end - start > 65536) {
          throw new Error('Invalid bounded file range');
        }
        const bytes = new Uint8Array(await file.slice(start, end).arrayBuffer());
        if (bytes.length !== end - start) throw new Error('Selected file was truncated or access was lost');
        return bytes;
      },
    });
  }
  async function output(handle) {
    const stream = await handle.createWritable({keepExistingData: false});
    let state = 'open';
    return Object.freeze({
      async write(bytes) {
        if (state !== 'open' || bytes.byteLength > 65536) throw new Error('Invalid output state or chunk');
        await stream.write(bytes);
      },
      async publish() {
        if (state !== 'open') throw new Error('Output is not open');
        state = 'closing';
        try { await stream.close(); state = 'published'; }
        catch (error) { state = 'failed'; throw error; }
      },
      async abort() {
        if (state === 'published' || state === 'aborted') return;
        await stream.abort(); state = 'aborted';
      },
    });
  }
  async function privateArtifact(namespace) {
    const root = await navigator.storage.getDirectory();
    const owner = await root.getDirectoryHandle(`supplier-${validName(namespace)}-work`, {create: true});
    const id = crypto.randomUUID();
    const directory = await owner.getDirectoryHandle(id, {create: true});
    let target;
    try {
      const file = await directory.getFileHandle('snapshot.logical', {create: true});
      target = await output(file);
      return Object.freeze({
        output: target,
        async source() { return source(await file.getFile()); },
        async dispose() {
          let failure;
          try { await target.abort(); } catch (error) { failure = error; }
          try { await owner.removeEntry(id, {recursive: true}); }
          catch (error) {
            if (failure) throw new AggregateError([failure, error], 'Private artifact cleanup failed');
            throw error;
          }
          if (failure) throw failure;
        },
      });
    } catch (primary) {
      try { await owner.removeEntry(id, {recursive: true}); }
      catch (cleanup) { throw new AggregateError([primary, cleanup], 'Private artifact creation cleanup failed'); }
      throw primary;
    }
  }
  window.supplierPlatform = Object.freeze({
    uuid: () => crypto.randomUUID(),
    withLock(name, action) {
      if (!navigator.locks?.request) return Promise.reject(new Error('Reliable cross-tab write lock unavailable'));
      return navigator.locks.request(`supplier-${validName(name)}-write`, {mode: 'exclusive'}, () => action());
    },
    readMetadata, compareAndSetMetadata, privateArtifact,
    async durableBackupOutput(namespace, locator) {
      validName(namespace); validName(locator);
      const owner = await (await navigator.storage.getDirectory()).getDirectoryHandle(`supplier-${namespace}-backups`, {create: true});
      // Generated UUIDs must not overwrite an existing published backup.
      try { await owner.getFileHandle(`${locator}.logical`); throw new Error('Backup locator already exists'); }
      catch (error) { if (error.name !== 'NotFoundError') throw error; }
      return output(await owner.getFileHandle(`${locator}.logical`, {create: true}));
    },
    async durableBackupSource(namespace, locator) {
      validName(namespace); validName(locator);
      const owner = await (await navigator.storage.getDirectory()).getDirectoryHandle(`supplier-${namespace}-backups`);
      return source(await (await owner.getFileHandle(`${locator}.logical`)).getFile());
    },
    // Drift 2.35.0 stores OPFS databases at drift_db/<name>/database. These
    // read-only checks are pinned to that worker version; never use create here.
    async databaseExists(name) {
      try {
        const root = await navigator.storage.getDirectory();
        const drift = await root.getDirectoryHandle('drift_db');
        const directory = await drift.getDirectoryHandle(validName(name));
        await directory.getFileHandle('database');
        return true;
      } catch (error) {
        if (error.name === 'NotFoundError') return false;
        throw error;
      }
    },
    async hasDatabasePrefix(prefix) {
      let drift;
      try { drift = await (await navigator.storage.getDirectory()).getDirectoryHandle('drift_db'); }
      catch (error) { if (error.name === 'NotFoundError') return false; throw error; }
      for await (const [name] of drift.entries()) { if (name.startsWith(prefix)) return true; }
      return false;
    },
    async capacityEstimate() {
      if (!navigator.storage?.estimate) return JSON.stringify({status: 'unsupported'});
      try {
        const {usage, quota} = await navigator.storage.estimate();
        if (!Number.isSafeInteger(usage) || usage < 0 || !Number.isSafeInteger(quota) || quota < 0) {
          return JSON.stringify({status: 'invalid', diagnostic: 'Invalid usage or quota estimate'});
        }
        return JSON.stringify({status: 'estimated', usage, quota, available: Math.max(0, quota - usage)});
      } catch (error) {
        return JSON.stringify({status: 'failed', diagnostic: String(error)});
      }
    },
    async sourceFromHandle(handle) { return source(await handle.getFile()); },
    outputFromHandle: output,
    // Call directly in the user gesture, before long-running generation.
    async pickInput() {
      if (!window.showOpenFilePicker) throw new Error('File picker is unavailable in this browser');
      const handles = await window.showOpenFilePicker({multiple: false});
      return source(await handles[0].getFile());
    },
    pickOutput(name) {
      if (!window.showSaveFilePicker) return Promise.reject(new Error('Streaming file save is unavailable in this browser'));
      return window.showSaveFilePicker({suggestedName: name});
    },
  });
})();
