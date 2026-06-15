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

## acorn

- **Version:** 8.11.3
- **Author:** Marijn Haverbeke `<marijnh@gmail.com>` and contributors
- **Source:** https://github.com/acornjs/acorn
- **License:** MIT
- **Used in:** `BrownBear/Resources/JS/brownbear-acorn.js` — the JavaScript parser used by
  `brownbear-esm-linker.js` to AST-rewrite MV3 `"type":"module"` service workers into code the
  headless JavaScriptCore context can run (JSC ships no ES-module loader on iOS).

```
MIT License

Copyright (C) 2012-2022 by various contributors (see AUTHORS)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

---

## Runestone

- **License:** MIT — referenced/depended-on per `CLAUDE.md` for the code editor engine.

---

## Free-proxy data sources (runtime, not bundled)

The optional **Free Proxy** browser (Settings → Proxy → Browse free proxies) fetches a public
list of free proxies at runtime; no list is bundled in the app. Sources:

- **ProxyScrape v4 free proxy list** (primary) — `https://api.proxyscrape.com/v4/free-proxy-list/get`.
  A free, no-auth public endpoint operated by ProxyScrape. Read-only; BrownBear claims no affiliation.
- **monosans/proxy-list** (fallback) — `https://github.com/monosans/proxy-list`, MIT-licensed,
  consumed as `proxies.json`.

The monosans `proxies.json` geolocation is derived from MaxMind's GeoLite2 data, which requires the
following attribution:

```
This product includes GeoLite2 Data created by MaxMind, available from
https://www.maxmind.com.
```

Free public proxies are run by unknown third parties; BrownBear surfaces a security warning and an
explicit-confirm gate before activating one, and never sends data through them without the user's action.
