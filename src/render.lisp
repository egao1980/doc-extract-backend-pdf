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

;;; Geometry and limits (pure) ---------------------------------------------------

(defun %raster-extent (points dpi)
  "Pixels that cover POINTS (1/72 inch) at DPI: the nearest integer, halves
up, at least 1. Exact rationals, so neither float error nor CL:ROUND's
halves-to-even changes the result."
  (max 1 (floor (+ (/ (* (rational points) (rational dpi)) 72) 1/2))))

(defun %check-raster-limits (width height limits max-pixels)
  "Refuse a WIDTH x HEIGHT BGRA bitmap that LIMITS or MAX-PIXELS do not allow,
with STACK-IMAGE:IMAGE-LIMIT-EXCEEDED. Neither check offers a restart."
  (stack-image:check-dimensions width height 4 :limits limits :format :pdf)
  (let ((pixels (* width height)))
    (when (and max-pixels (> pixels max-pixels))
      (error 'stack-image:image-limit-exceeded
             :limit :pixels :allowed max-pixels :actual pixels :format :pdf))))

;;; Handle lifetimes, in the shape of %WITH-DOCUMENT -----------------------------

(defun %call-with-page (doc index fn)
  "Call FN with page INDEX of DOC and close the page on every exit. A null
handle signals DOC-EXTRACT-ERROR, and nothing is closed."
  (let ((page (%call :load-page doc index)))
    (when (%null-handle-p page)
      (error 'doc-extract-error
             :format :pdf
             :message (format nil "failed to load PDF page ~D" index)))
    (unwind-protect (funcall fn page)
      (%call :close-page page))))

(defun %call-with-bitmap (width height fn)
  "Call FN with a WIDTH x HEIGHT BGRA bitmap whose buffer pdfium allocates and
owns, and destroy it on every exit. A null handle signals DOC-EXTRACT-ERROR,
and nothing is destroyed."
  (let ((bitmap (%call :bitmap-create-ex width height +fpdfbitmap-bgra+
                       (null-pointer) 0)))
    (when (%null-handle-p bitmap)
      (error 'doc-extract-error
             :format :pdf
             :message (format nil "failed to create a ~D x ~D bitmap" width height)))
    (unwind-protect (funcall fn bitmap)
      (%call :bitmap-destroy bitmap))))

;;; Copy -------------------------------------------------------------------------

(defun %copy-bgra-rows (buffer stride width height)
  "Packed R G B A octets, row-major, top row first, from the strided B G R A
rows of the foreign BUFFER. Row Y starts at byte Y x STRIDE; only its first
4 x WIDTH bytes are read."
  (declare (type fixnum stride width height))
  (let ((out (make-array (* 4 width height) :element-type '(unsigned-byte 8)))
        (dst 0))
    (declare (type (simple-array (unsigned-byte 8) (*)) out)
             (type fixnum dst))
    (dotimes (y height out)
      (let ((src (* y stride)))
        (declare (type fixnum src))
        (dotimes (x width)
          (setf (aref out dst) (mem-aref buffer :uint8 (+ src 2))
                (aref out (+ dst 1)) (mem-aref buffer :uint8 (+ src 1))
                (aref out (+ dst 2)) (mem-aref buffer :uint8 src)
                (aref out (+ dst 3)) (mem-aref buffer :uint8 (+ src 3)))
          (incf src 4)
          (incf dst 4))))))

(defun %bitmap-rgba-image (bitmap width height)
  "The :RGBA STACK-IMAGE:IMAGE held by the WIDTH x HEIGHT BITMAP. A null buffer,
or a stride below 4 x WIDTH, signals DOC-EXTRACT-ERROR before any byte is read."
  (let ((buffer (%call :bitmap-get-buffer bitmap))
        (stride (%call :bitmap-get-stride bitmap)))
    (when (%null-handle-p buffer)
      (error 'doc-extract-error :format :pdf :message "the bitmap has no buffer"))
    (unless (and (integerp stride) (>= stride (* 4 width)))
      (error 'doc-extract-error
             :format :pdf
             :message (format nil "bitmap stride ~A is below ~D (4 x width)"
                              stride (* 4 width))))
    (stack-image:make-image :width width :height height :format :rgba
                            :pixels (%copy-bgra-rows buffer stride width height))))

;;; Render -----------------------------------------------------------------------

(defun %render-page-native (document password index dpi format max-pixels limits)
  "Steps 2-9 of the file header. The handles nest document > page > bitmap, so
they are released in the reverse order on every exit, and before the format
conversion allocates."
  (stack-image:convert-image
   (%with-document document password
     (lambda (doc)
       (let ((count (or (%call :get-page-count doc) 0)))
         (when (>= index count)
           (error 'pdf-page-not-found
                  :index index :page-count count :format :pdf
                  :message (format nil "page index ~D is out of range (~D page~:P)"
                                   index count))))
       (%call-with-page doc index
         (lambda (page)
           (let ((width (%raster-extent (%call :get-page-width-f page) dpi))
                 (height (%raster-extent (%call :get-page-height-f page) dpi)))
             (%check-raster-limits width height limits max-pixels)
             (%call-with-bitmap width height
               (lambda (bitmap)
                 (%call :bitmap-fill-rect bitmap 0 0 width height +opaque-white+)
                 (%call :render-page-bitmap bitmap page 0 0 width height 0 +fpdf-annot+)
                 (%bitmap-rgba-image bitmap width height))))))))
   format))

(defun render-page (document index &key (dpi 72) (format :rgba) max-pixels
                                      (limits stack-image:*image-limits*) password)
  "Rasterize page INDEX (zero-based) of the PDF DOCUMENT at DPI → a
STACK-IMAGE:IMAGE in pixel FORMAT, white background (see the file header).
Without libpdfium and without *PDFIUM-FN-TABLE*, signals PDFIUM-NOT-LOADED
with USE-VALUE (return a supplied image) and RETRY (check again, for example
after LOAD-PDFIUM in a handler)."
  (check-type index (integer 0))
  (check-type dpi (real (0)))
  (check-type format (member :gray :gray-alpha :rgb :rgba))
  (check-type max-pixels (or null (integer 1)))
  (check-type limits stack-image:image-limits)
  (check-type password (or null string))
  (tagbody
   :again
     (unless (or *pdfium-fn-table* *pdfium-loaded*)
       (restart-case
           (error 'pdfium-not-loaded :format :pdf :message "libpdfium is not loaded")
         (use-value (value)
           :report "Return a supplied image from RENDER-PAGE"
           :interactive (lambda ()
                          (format *query-io* "Image form: ")
                          (force-output *query-io*)
                          (list (eval (read *query-io*))))
           (return-from render-page value))
         (retry ()
           :report "Retry after loading libpdfium or binding *PDFIUM-FN-TABLE*"
           (go :again)))))
  (%render-page-native document password index dpi format max-pixels limits))
