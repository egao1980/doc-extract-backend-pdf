# doc-extract-backend-pdf

[`doc-extract-protocol`](https://github.com/egao1980/doc-extract-protocol) backend for **PDF** via [PDFium](https://pdfium.googlesource.com/pdfium/) (`libpdfium`) CFFI.

This checkout does **not** vendor a pdfium build (hundreds of MB). Tests pass without the native library: missing `libpdfium` is a soft load failure; the GFs signal `pdfium-not-loaded` (a `doc-extract-unsupported`) with `use-value` / `retry`.

```lisp
(asdf:load-system "doc-extract-backend-pdf")

(let ((b (doc-extract-backend-pdf:make-pdf-doc-extract-backend)))
  (handler-bind ((doc-extract-protocol:doc-extract-unsupported
                  (lambda (c) (use-value "" c))))
    (doc-extract-protocol:extract-text b #p"x.pdf" :format :pdf)))
```

## API

| Binding | Role |
|---------|------|
| `pdf-doc-extract-backend` | CLOS class (`doc-extract-backend`) |
| `make-pdf-doc-extract-backend` | `&key cffi-library-path driver password` |
| `use-pdf-doc-extract-backend` | bind `*doc-extract-backend*` |
| `extract-text` / `extract-metadata` / `extract-sections` | protocol GFs (0.1) |
| `extract-document` / `normalize-document` | `extracted-document` (0.1.1; pages, ids, provenance) |
| `+pdfium-extractor-priority+` | `20` — `register-extractor` for `:pdf` / `application/pdf` |
| `pdfium-available-p` / `load-pdfium` | native probe (never crashes ASDF) |
| `*pdfium-fn-table*` | optional FPDF_* stand-in plist (tests) |
| `pdf-driver` | kafka-style GF table (`:extract-text` …) |

Source may be a pathname, a filesystem string, a `%PDF…` string, or an `(unsigned-byte 8)` vector.

`extract-metadata` is a plist (`:format :pdf`, `:page-count`, plus cheap `FPDF_GetMetaText` tags when present: `:title` `:author` `:subject` `:keywords` `:creator` `:producer` `:creation-date` `:mod-date`). `extract-sections` is one `extracted-section` per page (`"Page N"`).

`extract-document` (and `normalize-document`) return a first-class `extracted-document`: one section + text-block per page, `page-info` list, provenance page numbers, then `ensure-ids`. This overrides the protocol's sections→document shim. Load of this system registers `pdf-doc-extract-backend` for `:pdf` at priority **20** (colocated HTML/office are 10; corporate docling/unstructured should register higher).

**Live `extract-document` needs a native pdfium overlay.** Mock-driver and `*pdfium-fn-table*` tests stay green in default CI without `libpdfium`. Overlay binaries are not in-tree: `publish-oci.yml` downloads a pinned [pdfium-binaries](https://github.com/bblanchon/pdfium-binaries) build and publishes it via `publish-native-package.yml`. Source-only Lisp still publishes via `publish-checkout.yml`.

CFFI subset: `FPDF_InitLibrary` / `FPDF_DestroyLibrary`, `FPDF_LoadMemDocument` / `FPDF_LoadDocument` / `FPDF_CloseDocument`, `FPDF_GetPageCount` / `FPDF_LoadPage` / `FPDF_ClosePage`, `FPDFText_LoadPage` / `FPDFText_CountChars` / `FPDFText_GetText` / `FPDFText_ClosePage`, `FPDF_GetMetaText` (+ `FPDF_GetLastError`).

## Load strategy

Absolute-path `cffi:load-foreign-library` only. **Never** `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`. `load-foreign-library` is not called unless a file was `probe-file`'d (kafka rule). Search order:

1. Backend slot `cffi-library-path` (at GF time)
2. Env `PDFIUM_LIBRARY` (absolute file)
3. Overlay dest: `native/` and `lib/<os>-<arch>/` next to the ASDF system (plus optional dir `PDFIUM_NATIVE`)

ASDF load calls `load-pdfium` and swallows a miss (`warn`). Consumers `(asdf:load-system "doc-extract-backend-pdf")` — no `ensure-*` helper required when the overlay is present.

Inject a driver so unit tests never `dlopen`:

```lisp
(doc-extract-backend-pdf:make-pdf-doc-extract-backend
 :driver (list :extract-text (lambda (backend source &key format)
                               (declare (ignore backend source format))
                               "hello")))
```

Or bind `*pdfium-fn-table*` to a plist of FPDF_* functions and exercise the real extract loop without a native lib.

## Native overlay

`.asd` `:cl-repo` lists expected sonames even when binaries are not in-tree:

| Platform | Inventory |
|----------|-----------|
| linux/amd64, linux/arm64 | `libpdfium.so`, `libpdfium.so.1` |
| darwin/arm64 | `libpdfium.dylib`, `libpdfium.1.dylib` |
| windows/amd64 | `pdfium.dll`, `libpdfium.dll` |

Stage locally into `lib/<os>-<arch>/` (gitignored) or set `PDFIUM_LIBRARY`. Do not commit a Chromium-sized pdfium tree.

### Publishing overlays (`publish-oci.yml`)

Owning-repo native publish, same reusable workflow as [`event-backend-libuv`](https://github.com/egao1980/event-backend-libuv): no grovel, no Chromium source. Each matrix job downloads a **prebuilt** `libpdfium` from [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries) (pin `PDFIUM_BINARIES_TAG`, currently **`chromium/8035`** / PDFium 154.0.8035.0) via `scripts/stage-pdfium.sh` (Unix) or `scripts/stage-pdfium.ps1` (Windows). The script stages overlay sonames into `lib/<os>-<arch>/` and copies them flat into `native-bundle/` (`libpdfium.so` + `libpdfium.so.1`, `libpdfium.dylib` + `libpdfium.1.dylib`, or `pdfium.dll` + `libpdfium.dll`). Artifacts are `native-<os>-<arch>`. The `publish` job calls `egao1980/cl-repository/.github/workflows/publish-native-package.yml@main` with `package-name: doc-extract-backend-pdf` and `source-paths` of the `.asd`, `src`, `LICENSE`, `README.md`. The packager honors `:cl-repo` `:overlays`.

Dispatch (needs `packages:write` on GHCR):

```bash
gh workflow run publish-oci.yml -R egao1980/doc-extract-backend-pdf -f version=0.1.2
# optional: -f registry=ghcr.io
# or push a v* tag (version is the tag without the leading v)
```

Local stage (gitignored; do not commit binaries):

```bash
./scripts/stage-pdfium.sh            # detect host, or:
./scripts/stage-pdfium.sh darwin arm64
```

Do **not** dispatch `publish-checkout.yml` / `publish-source.yml` for this repo: `:cl-repo` `:overlays` makes the source packager open `lib/<os>-<arch>/libpdfium*` (gitignored), so that job fails. Lisp + overlays ship together via `publish-oci.yml` only. Overlay binaries carry pdfium's own license (**BSD-3-Clause**); this Lisp tree remains **MIT**. `lib/`, `native-bundle/`, and downloaded tarballs are gitignored.

## Tests

`asdf:test-system "doc-extract-backend-pdf"` is green without `libpdfium` (mock driver + mocked FFI, including `extract-document` ids/pages). A live extract is skipped unless `pdfium-available-p`.

## License

MIT — see [LICENSE](LICENSE) for this Lisp tree. Staged/published `libpdfium` overlays come from [pdfium-binaries](https://github.com/bblanchon/pdfium-binaries) and are **BSD-3-Clause** (PDFium).
