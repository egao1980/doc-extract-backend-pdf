;;;; RENDER-PAGE: rasterize one PDF page into a STACK-IMAGE:IMAGE (image-protocol).
;;;;
;;;; (render-page document index &key (dpi 72) (format :rgba) max-pixels
;;;;                                  (limits stack-image:*image-limits*) password)
;;;;
;;;; DOCUMENT is a source as for EXTRACT-TEXT: a pathname, a filesystem string, a
;;;; "%PDF…" string or an octet vector. INDEX is the zero-based page index, as for
;;;; FPDF_LoadPage (PAGE-INFO numbers count from 1). PASSWORD opens an encrypted
;;;; document.
;;;;
;;;; The arguments are checked first, in this order, with CHECK-TYPE (a TYPE-ERROR
;;;; with a STORE-VALUE restart): INDEX (INTEGER 0); DPI (REAL (0)); FORMAT, one of
;;;; STACK-IMAGE:PIXEL-FORMATS (:GRAY :GRAY-ALPHA :RGB :RGBA); MAX-PIXELS, NIL or
;;;; (INTEGER 1); LIMITS, a STACK-IMAGE:IMAGE-LIMITS; PASSWORD, NIL or a STRING.
;;;;
;;;; Every pdfium call goes through %CALL with the key named below, so a
;;;; *PDFIUM-FN-TABLE* can stand in for libpdfium.
;;;;   1. When there is no *PDFIUM-FN-TABLE* and *PDFIUM-LOADED* is false (libpdfium
;;;;      did not load), signal PDFIUM-NOT-LOADED (FORMAT :PDF) inside two restarts,
;;;;      as the extract functions do: USE-VALUE (an image, which RENDER-PAGE
;;;;      returns) and RETRY (start again from this step).
;;;;   2. Open DOCUMENT as the extract functions do (:LOAD-DOCUMENT for a pathname or
;;;;      filesystem string, else :LOAD-MEM-DOCUMENT). A null handle signals
;;;;      DOC-EXTRACT-ERROR (FORMAT :PDF) whose message names FPDF_GetLastError,
;;;;      "failed to load PDF (password)".
;;;;   3. When INDEX >= (:GET-PAGE-COUNT doc), signal PDF-PAGE-NOT-FOUND with INDEX and
;;;;      PAGE-COUNT (FORMAT :PDF). No page is loaded.
;;;;   4. (:LOAD-PAGE doc index). A null handle signals DOC-EXTRACT-ERROR.
;;;;   5. Size. W and H are (:GET-PAGE-WIDTH-F page) and (:GET-PAGE-HEIGHT-F page), in
;;;;      points: the visible box (CropBox) after the page's /Rotate, as pdfium
;;;;      reports it. With exact rationals, the bitmap is
;;;;        width  = max(1, floor(rational(W) × rational(DPI) / 72 + 1/2))
;;;;        height = max(1, floor(rational(H) × rational(DPI) / 72 + 1/2))
;;;;      (round to nearest, halves up). A 300 × 200 pt page is 300 × 200 at 72 dpi
;;;;      and 625 × 417 at 150; A4 (595.2756 × 841.8898 pt as single floats) is
;;;;      2480 × 3508 at 300; a 5 × 5 pt page is 3 × 3 at 36 dpi.
;;;;   6. Limits, before any bitmap exists:
;;;;        (STACK-IMAGE:CHECK-DIMENSIONS width height 4 :LIMITS limits :FORMAT :PDF)
;;;;      (4: the bitmap holds BGRA), then, when MAX-PIXELS is given and
;;;;      width × height > MAX-PIXELS, STACK-IMAGE:IMAGE-LIMIT-EXCEEDED with LIMIT
;;;;      :PIXELS, ALLOWED MAX-PIXELS, ACTUAL width × height and FORMAT :PDF. Neither
;;;;      offers a restart.
;;;;   7. Render:
;;;;        bitmap = (:BITMAP-CREATE-EX width height 4 <null pointer> 0)
;;;;                 FPDFBitmap_BGRA (+FPDFBITMAP-BGRA+); pdfium allocates and owns the
;;;;                 buffer. A null handle signals DOC-EXTRACT-ERROR.
;;;;        (:BITMAP-FILL-RECT bitmap 0 0 width height #xFFFFFFFF)   opaque white
;;;;        (:RENDER-PAGE-BITMAP bitmap page 0 0 width height 0 1)
;;;;                 rotate 0 (the page's own /Rotate still applies), flags FPDF_ANNOT
;;;;   8. Copy. buffer = (:BITMAP-GET-BUFFER bitmap) and stride =
;;;;      (:BITMAP-GET-STRIDE bitmap). A null buffer, or a stride below 4 × width,
;;;;      signals DOC-EXTRACT-ERROR. Row y of the bitmap starts at byte y × stride, and
;;;;      its pixel x is the bytes B G R A at 4x … 4x + 3 of the row. The :RGBA image
;;;;      has, at pixel (x, y), the bytes R G B A: row-major, top row first, no padding.
;;;;      Bytes past 4 × width in a row are never read. Alpha is copied; after the
;;;;      opaque fill it is 255 everywhere.
;;;;   9. Result: (STACK-IMAGE:CONVERT-IMAGE rgba FORMAT), so gray is image-protocol's
;;;;      BT.601 luma and :GRAY is exactly (convert-image (render-page … :format :rgba)
;;;;      :gray). DEPTH 8, COLOR-SPACE :SRGB, ORIENTATION, ICC-PROFILE and GAMMA NIL.
;;;;  10. Cleanup with UNWIND-PROTECT on every exit, normal or not, for each handle that
;;;;      exists: (:BITMAP-DESTROY bitmap), then (:CLOSE-PAGE page), then
;;;;      (:CLOSE-DOCUMENT doc).

(in-package #:doc-extract-backend-pdf)

(defun %render-pending (name)
  "Contract stub for RENDER-PAGE. Every call is replaced by the implementation,
then this function is deleted."
  (error "doc-extract-backend-pdf render pending: ~A" name))

(defun render-page (document index &key (dpi 72) (format :rgba) max-pixels
                                      (limits stack-image:*image-limits*) password)
  "Rasterize page INDEX (zero-based) of the PDF DOCUMENT at DPI → a
STACK-IMAGE:IMAGE in pixel FORMAT, white background (see the file header)."
  (declare (ignorable document index dpi format max-pixels limits password))
  (%render-pending 'render-page))
