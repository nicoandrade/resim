import { optimize } from 'svgo/browser';

// The explicit list replaces SVGO's default preset. Preserve geometry, IDs,
// styles, metadata, and numeric precision; only sort attributes and serialize.
globalThis.ResimSVGOptimize = function (input, comments, elements) {
  if (typeof input !== 'string' || !Array.isArray(comments) ||
      comments.some(value => typeof value !== 'string') || !Array.isArray(elements)) {
    throw new Error('Expected SVG text and parsed XML comments.');
  }
  const originalComments = Object.freeze(comments.slice());
  let index = 0;
  let elementIndex = 0;
  const result = optimize(input, {
    multipass: false,
    plugins: ['sortAttrs', {
      name: 'resimPreserveContent',
      // Restore XML-parser text slots and comments after SVGO's parser trims
      // their edges. The application's independent validator is authoritative.
      fn: () => ({
        element: {
          enter(node) {
            const entry = elements[elementIndex++];
            if (!entry || entry.name !== node.name || !Array.isArray(entry.slots)) {
              throw new Error('Element structure changed.');
            }
            const children = node.children.filter(child => child.type !== 'text' && child.type !== 'cdata');
            if (entry.slots.length !== children.length + 1 ||
                entry.slots.some(value => typeof value !== 'string')) {
              throw new Error('Text slots changed.');
            }
            node.children = [];
            for (let slot = 0; slot < entry.slots.length; slot++) {
              if (entry.slots[slot]) node.children.push({ type: 'text', value: entry.slots[slot] });
              if (slot < children.length) node.children.push(children[slot]);
            }
          },
        },
        comment: {
          enter(node) {
            if (index >= originalComments.length) throw new Error('Comment count changed.');
            node.value = originalComments[index++];
          },
        },
      }),
    }],
    js2svg: { pretty: false },
  }).data;
  if (index !== originalComments.length || elementIndex !== elements.length) {
    throw new Error('Content count changed.');
  }
  return result;
};
