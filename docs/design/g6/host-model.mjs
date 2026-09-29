import {validateSchema} from './graph-model.mjs';

// Normalize the entire boundary before mutating either DOM or graph state.
export function hostPayload(value) {
  if (!value || value.version !== 1) throw new Error('Unsupported host version');
  const schema = validateSchema(value.schema);
  if (!schema.nodes.length) throw new Error('Empty ontology');
  if (!schema.nodes.some(n => n.id === value.selected)) throw new Error('Unknown selected object');
  const counts = {};
  for (const node of schema.nodes) {
    const count = value.counts?.[node.id];
    if (count !== undefined && (!Number.isSafeInteger(count) || count < 0)) throw new Error('Invalid record count');
    if (count !== undefined) counts[node.id] = count;
  }
  if (typeof value.dark !== 'boolean' || typeof value.reducedMotion !== 'boolean') throw new Error('Invalid appearance');
  return {schema, counts, selected:value.selected, dark:value.dark,
    reducedMotion:value.reducedMotion, textScale:Math.max(1, Math.min(2, Number(value.textScale) || 1))};
}
