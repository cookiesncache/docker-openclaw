# Third-party notices

This image bundles and redistributes **OpenClaw** and the **Node.js** runtime (including **npm**).
The packaging in this repository (Dockerfile, s6-overlay service definitions, and the Unraid
template) is licensed under GPL-3.0 (see [LICENSE](LICENSE)); the bundled software remains under
its own license, reproduced or referenced below.

## OpenClaw

- Project: <https://github.com/openclaw/openclaw>
- License: MIT
- Upstream third-party notices: <https://github.com/openclaw/openclaw/blob/main/THIRD_PARTY_NOTICES.md>

```
MIT License

Copyright (c) 2026 OpenClaw Foundation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Node.js (and its bundled components)

The Node.js runtime is copied into this image from the upstream OpenClaw image, which is built on
`node:24-bookworm-slim`. Copying the binary rather than installing the NodeSource `nodejs` package
guarantees the ABI match with OpenClaw's prebuilt native modules — but the NodeSource package used
to supply `/usr/share/doc/nodejs/copyright`, so the notice is carried explicitly instead.

- Project: <https://nodejs.org>
- License: MIT, plus the licenses of the components Node.js bundles (OpenSSL, ICU, V8, zlib,
  brotli, c-ares, libuv, and others)
- **The complete, authoritative text ships inside this image at `/licenses/NODEJS_LICENSE`**,
  copied verbatim from the upstream image's `/usr/local/LICENSE`. Read it with:

  ```bash
  docker run --rm --entrypoint cat ghcr.io/cookiesncache/openclaw:latest /licenses/NODEJS_LICENSE
  ```

## npm

Bundled with the Node.js runtime above and used to install OpenClaw plugins at runtime.

- Project: <https://github.com/npm/cli>
- License: Artistic License 2.0
- Full text ships in the image at `/usr/local/lib/node_modules/npm/LICENSE`.
