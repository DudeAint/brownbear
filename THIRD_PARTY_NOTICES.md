# Third-Party Notices

BrownBear is MIT-licensed. It bundles the following third-party code, whose licenses are reproduced
or referenced below. We retain each component's copyright and license notice as required.

---

## fake-indexeddb

- **Version:** 3.1.7
- **Author:** Jeremy Scheff `<jdscheff@gmail.com>` (https://dumbmatter.com/)
- **Source:** https://github.com/dumbmatter/fakeIndexedDB
- **License:** Apache License 2.0
- **Used in:** `BrownBear/Resources/JS/brownbear-indexeddb.js` — an in-memory IndexedDB implementation
  for headless JavaScriptCore contexts (extension service workers and the userscript background
  runner), which JSC does not provide. Vendored as a generated IIFE bundle (see that file's header for
  the exact, reproducible build command). v3.1.7 is pinned because it carries its own structured-clone
  and needs no DOM/`structuredClone` globals, so it runs unmodified in a bare JSContext.

```
Copyright (c) Jeremy Scheff

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

---

## Runestone

- **License:** MIT — referenced/depended-on per `CLAUDE.md` for the code editor engine.
