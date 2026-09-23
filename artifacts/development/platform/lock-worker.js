onmessage = async ({data}) => { try { await navigator.locks.request(data, {ifAvailable:true}, lock => postMessage({acquired:lock!==null})); } catch(error) { postMessage({error:String(error)}); } };
