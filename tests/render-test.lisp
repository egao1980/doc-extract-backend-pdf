;;;; RENDER-PAGE (src/render.lisp). Two halves:
;;;;  - a mock *PDFIUM-FN-TABLE* whose bitmap has stride padding and a known BGRA
;;;;    pattern, which pins the calls, the size rule, the limits, the byte order,
;;;;    the stride copy, the conditions and the cleanup. These run without libpdfium.
;;;;  - live renders of tests/fixtures/raster.pdf through libpdfium, skipped when it
;;;;    is not present (stage it with scripts/stage-pdfium.sh). Expected sizes follow
;;;;    the size rule. Probe colours follow the page design, and the pixel-count
;;;;    bands are pypdfium2 5.15.2 renders (pdfium 159.0.8149) ± 3 %. See
;;;;    tests/fixtures/PROVENANCE.md and make-raster-pdf.py.

(in-package #:doc-extract-backend-pdf/tests)

(defun %signals-type (thunk type)
  "True when THUNK signals a condition of TYPE (any other condition: false)."
  (handler-case (progn (funcall thunk) nil)
    (condition (c) (typep c type))))

(defun %condition-of (thunk)
  (handler-case (progn (funcall thunk) nil)
    (condition (c) c)))

(defun %call-with (function &rest args)
  "APPLY at run time, so ill-typed arguments reach the type check."
  (apply function args))

(defun %shape (image)
  (list (stack-image:image-width image) (stack-image:image-height image)
        (stack-image:image-format image)))

(defun %px (image) (coerce (stack-image:image-pixels image) 'list))

;;; Mock ---------------------------------------------------------------------

(defun %mock-bgra (x y)
  "The mock renderer's pixel (x, y), as (b g r a). (0, 0) is left unpainted."
  (list (mod (+ (* 10 x) 1) 256) (mod (+ (* 20 y) 2) 256) (mod (+ (* 30 (+ x y)) 3) 256)
        (if (and (= x 1) (= y 0)) 200 255)))

(defun make-raster-mock (&key (width 3.0) (height 2.0) (pages 1) (pad 12)
                              (load-doc-ok t) (load-page-ok t) (create-ok t) (buffer-ok t)
                              stride)
  "→ (values fn-table log-function). A document of PAGES pages of WIDTH × HEIGHT
points. Its bitmaps have a stride of 4 × width + PAD (or STRIDE when given),
padding filled with #xEE. FillRect writes its colour; rendering writes
%MOCK-BGRA everywhere but (0, 0). LOG-FUNCTION returns the calls, oldest first."
  (let ((log '()) (bitmaps (make-hash-table)))
    (labels ((note (&rest entry) (push entry log))
             (info (bitmap) (gethash (cffi:pointer-address bitmap) bitmaps))
             (put (bitmap x y bytes)
               (destructuring-bind (mem w h s) (info bitmap)
                 (declare (ignore w h))
                 (loop for b in bytes for i from 0
                       do (setf (cffi:mem-aref mem :uint8 (+ (* y s) (* 4 x) i)) b)))))
      (values
       (list :init-library (lambda () t)
             :destroy-library (lambda () t)
             :get-last-error (lambda () 4)
             :load-mem-document (lambda (buf size password)
                                  (declare (ignore buf))
                                  (note :load-mem-document size password)
                                  (if load-doc-ok (cffi:make-pointer 1) (cffi:null-pointer)))
             :load-document (lambda (path password)
                              (note :load-document path password)
                              (if load-doc-ok (cffi:make-pointer 1) (cffi:null-pointer)))
             :close-document (lambda (doc) (declare (ignore doc)) (note :close-document) t)
             :get-page-count (lambda (doc) (declare (ignore doc)) (note :get-page-count) pages)
             :load-page (lambda (doc index)
                          (declare (ignore doc))
                          (note :load-page index)
                          (if load-page-ok (cffi:make-pointer 2) (cffi:null-pointer)))
             :close-page (lambda (page) (declare (ignore page)) (note :close-page) t)
             :get-page-width-f (lambda (page) (declare (ignore page)) (note :get-page-width-f) width)
             :get-page-height-f (lambda (page) (declare (ignore page)) (note :get-page-height-f) height)
             :bitmap-create-ex
             (lambda (w h format first-scan stride-arg)
               (note :bitmap-create-ex w h format (cffi:null-pointer-p first-scan) stride-arg)
               (if create-ok
                   (let* ((s (+ (* 4 w) pad))
                          (mem (cffi:foreign-alloc :uint8 :count (* s h) :initial-element #xEE)))
                     (setf (gethash (cffi:pointer-address mem) bitmaps) (list mem w h s))
                     mem)
                   (cffi:null-pointer)))
             :bitmap-fill-rect
             (lambda (bitmap left top w h color)
               (note :bitmap-fill-rect left top w h color)
               (loop for y from top below (+ top h)
                     do (loop for x from left below (+ left w)
                              do (put bitmap x y (list (ldb (byte 8 0) color) (ldb (byte 8 8) color)
                                                       (ldb (byte 8 16) color) (ldb (byte 8 24) color)))))
               1)
             :render-page-bitmap
             (lambda (bitmap page start-x start-y w h rotate flags)
               (declare (ignore page))
               (note :render-page-bitmap start-x start-y w h rotate flags)
               (dotimes (y h)
                 (dotimes (x w)
                   (unless (and (= x 0) (= y 0)) (put bitmap x y (%mock-bgra x y))))))
             :bitmap-get-buffer (lambda (bitmap)
                                  (note :bitmap-get-buffer)
                                  (if buffer-ok bitmap (cffi:null-pointer)))
             :bitmap-get-stride (lambda (bitmap)
                                  (note :bitmap-get-stride)
                                  (or stride (fourth (info bitmap))))
             :bitmap-destroy (lambda (bitmap)
                               (note :bitmap-destroy)
                               (cffi:foreign-free (first (info bitmap)))
                               (remhash (cffi:pointer-address bitmap) bitmaps)))
       (lambda () (reverse log))))))

(defmacro with-raster-mock ((log &rest mock-args) &body body)
  "Run BODY with a raster mock as *PDFIUM-FN-TABLE* and the real library off, so
a call the mock does not provide signals instead of reaching libpdfium."
  (let ((table (gensym)))
    `(multiple-value-bind (,table ,log) (make-raster-mock ,@mock-args)
       (declare (ignorable ,log))
       (let ((doc-extract-backend-pdf::*pdfium-loaded* nil)
             (doc-extract-backend-pdf::*pdfium-library-inited* nil)
             (doc-extract-backend-pdf:*pdfium-fn-table* ,table))
         ,@body))))

(defun %names (log) (mapcar #'first (funcall log)))

(defun %in-order-p (names log)
  "True when NAMES occur in LOG's calls in this order (others may come between)."
  (let ((calls (%names log)))
    (loop for n in names
          always (let ((p (position n calls))) (and p (setf calls (nthcdr (1+ p) calls)))))))

(defun %entry (name log) (rest (assoc name (funcall log))))

(defun %render (&rest args)
  (apply #'doc-extract-backend-pdf:render-page *hello-pdf* args))

;;; Mock: calls, copy, formats -----------------------------------------------

(deftest render-mock-rgba-exact
  (with-raster-mock (log)
    (let ((out (ignore-errors (%render 0))))
      (ok (and out (equal '(3 2 :rgba) (%shape out))))
      (ok (and out (equal '(255 255 255 255 33 2 11 200 63 2 21 255
                            33 22 1 255 63 22 11 255 93 22 21 255)
                          (%px out)))
          "R G B A from B G R A, alpha copied, padding skipped, (0, 0) from the white fill")
      (ok (and out (= 8 (stack-image:image-depth out)) (eq :srgb (stack-image:image-color-space out))
               (null (stack-image:image-orientation out)) (null (stack-image:image-icc-profile out))))
      (ok (equal '(3 2 4 t 0) (%entry :bitmap-create-ex log)) "BGRA, pdfium-owned buffer")
      (ok (equal '(0 0 3 2 #xFFFFFFFF) (%entry :bitmap-fill-rect log)) "opaque white")
      (ok (equal '(0 0 3 2 0 1) (%entry :render-page-bitmap log)) "rotate 0, FPDF_ANNOT")
      (ok (equal '(0) (%entry :load-page log)))
      (ok (%in-order-p '(:get-page-count :load-page :get-page-width-f :bitmap-create-ex
                         :bitmap-fill-rect :render-page-bitmap :bitmap-destroy
                         :close-page :close-document)
                       log))
      (ok (= 1 (count :bitmap-destroy (%names log))))
      (ok (= 1 (count :close-document (%names log)))))))

(deftest-parametrize render-mock-formats
    ((format expected)
     (:rgba '(255 255 255 255 33 2 11 200 63 2 21 255 33 22 1 255 63 22 11 255 93 22 21 255))
     (:rgb '(255 255 255 33 2 11 63 2 21 33 22 1 63 22 11 93 22 21))
     ;; BT.601, floor((299 r + 587 g + 114 b + 500) / 1000), as STACK-IMAGE:CONVERT-IMAGE.
     (:gray '(255 12 22 23 33 43))
     (:gray-alpha '(255 255 12 200 22 255 23 255 33 255 43 255)))
  (with-raster-mock (log)
    (let ((out (ignore-errors (%render 0 :format format))))
      (ok (and out (equal (list 3 2 format) (%shape out))))
      (ok (and out (equal expected (%px out)))))))

(deftest-parametrize render-mock-stride
    ((width height dpi pad)
     (3.0 2.0 72 0)
     (3.0 2.0 72 1)
     (37.0 23.0 72 12)
     (37.0 23.0 144 64)
     (10.0 10.0 21.6 4))                ; 3.0000000529 px a side
  (with-raster-mock (log :width width :height height :pad pad)
    (let* ((out (ignore-errors (%render 0 :dpi dpi)))
           (w (and out (stack-image:image-width out)))
           (px (and out (stack-image:image-pixels out))))
      (ok (and out (= (* w (stack-image:image-height out) 4) (length px))))
      (ok (and out
               (loop for y below (stack-image:image-height out)
                     always (loop for x below w
                                  for o = (* 4 (+ (* y w) x))
                                  for want = (if (and (= x 0) (= y 0))
                                                 '(255 255 255 255)
                                                 (destructuring-bind (b g r a) (%mock-bgra x y)
                                                   (list r g b a)))
                                  always (equal want (coerce (subseq px o (+ o 4)) 'list)))))
          "every row copied from y × stride, no #xEE padding byte"))))

(deftest-parametrize render-size-rule
    ((width height dpi expected-w expected-h)
     (300.0 200.0 72 300 200)
     (300.0 200.0 150 625 417)            ; 416.67
     (612.0 792.0 150 1275 1650)
     (595.2756 841.8898 300 2480 3508)    ; A4
     (5.0 5.0 36 3 3)                     ; 2.5: halves up
     (3.0 3.0 36 2 2)                     ; 1.5
     (7.0 1.0 36 4 1)                     ; 3.5, 0.5
     (5.0 5.0 1 1 1)                      ; 0.07: at least 1
     (100.0 50.0 96.5 134 67)
     (144.0 72.0 200.0 400 200)
     (300.0 200.0 1/3 1 1))
  ;; Limits of 1 refuse before any bitmap, and report the computed size.
  (flet ((actual (limits)
           (with-raster-mock (log :width width :height height)
             (let ((c (%condition-of (lambda () (%render 0 :dpi dpi :limits limits)))))
               (list (and (typep c 'stack-image:image-limit-exceeded)
                          (stack-image:image-limit-exceeded-actual c))
                     (find :bitmap-create-ex (%names log)))))))
    (let ((w (actual (stack-image:make-image-limits :max-width 0)))
          (h (actual (stack-image:make-image-limits :max-height 0))))
      (ok (equal (list expected-w nil) w) "width")
      (ok (equal (list expected-h nil) h) "height"))))

;;; Mock: limits -------------------------------------------------------------

(deftest render-limits
  (with-raster-mock (log :width 300.0 :height 200.0)
    (let ((c (%condition-of (lambda () (%render 0 :max-pixels 59999)))))
      (ok (typep c 'stack-image:image-limit-exceeded))
      (ok (and (typep c 'stack-image:image-limit-exceeded)
               (equal '(:pixels 59999 60000 :pdf)
                      (list (stack-image:image-limit-exceeded-limit c)
                            (stack-image:image-limit-exceeded-allowed c)
                            (stack-image:image-limit-exceeded-actual c)
                            (stack-image:image-error-format c)))))
      (ok (null (find :bitmap-create-ex (%names log))) "refused before allocating")
      (ok (%in-order-p '(:close-page :close-document) log) "and the page and document are closed")))
  (with-raster-mock (log :width 300.0 :height 200.0)
    (ok (equal '(300 200 :rgba) (ignore-errors (%shape (%render 0 :max-pixels 60000))))))
  (with-raster-mock (log :width 300.0 :height 200.0)
    (let ((c (%condition-of (lambda () (%render 0 :dpi 150 :max-pixels 60000)))))
      (ok (and (typep c 'stack-image:image-limit-exceeded)
               (= (* 625 417) (stack-image:image-limit-exceeded-actual c))))))
  (with-raster-mock (log :width 300.0 :height 200.0)
    (let* ((stack-image:*image-limits* (stack-image:make-image-limits :max-pixels 1000))
           (c (%condition-of (lambda () (%render 0)))))
      (ok (and (typep c 'stack-image:image-limit-exceeded)
               (eq :pixels (stack-image:image-limit-exceeded-limit c)))
          "the default LIMITS is *IMAGE-LIMITS* at call time")))
  (with-raster-mock (log :width 6000.0 :height 6000.0)
    (let ((c (%condition-of (lambda () (%render 0 :dpi 300)))))
      (ok (and (typep c 'stack-image:image-limit-exceeded)
               (eq :width (stack-image:image-limit-exceeded-limit c))
               (= 25000 (stack-image:image-limit-exceeded-actual c)))
          "the default limits: 16384 px a side")
      (ok (null (find :bitmap-create-ex (%names log)))))))

;;; Mock: errors and cleanup -------------------------------------------------

(deftest render-page-index
  (with-raster-mock (log :pages 2)
    (let ((c (%condition-of (lambda () (%render 2)))))
      (ok (typep c 'doc-extract-backend-pdf:pdf-page-not-found))
      (ok (typep c 'doc-extract-protocol:doc-extract-error))
      (ok (and (typep c 'doc-extract-backend-pdf:pdf-page-not-found)
               (= 2 (doc-extract-backend-pdf:pdf-page-not-found-index c))
               (= 2 (doc-extract-backend-pdf:pdf-page-not-found-page-count c))))
      (ok (null (find :load-page (%names log))) "no page is loaded")
      (ok (find :close-document (%names log)))))
  (with-raster-mock (log :pages 2)
    (ok (equal '(3 2 :rgba) (ignore-errors (%shape (%render 1)))))
    (ok (equal '(1) (%entry :load-page log)))))

(deftest render-native-failures
  (with-raster-mock (log :load-doc-ok nil)
    (let ((c (%condition-of (lambda () (%render 0)))))
      (ok (typep c 'doc-extract-protocol:doc-extract-error))
      (ok (and (typep c 'doc-extract-protocol:doc-extract-error)
               (search "password" (or (doc-extract-protocol:doc-extract-error-message c) "")))
          "names FPDF_GetLastError")
      (ok (null (find :close-document (%names log))) "nothing to close")))
  (with-raster-mock (log :load-page-ok nil)
    (ok (%signals-type (lambda () (%render 0)) 'doc-extract-protocol:doc-extract-error))
    (ok (find :close-document (%names log)))
    (ok (null (find :close-page (%names log)))))
  (with-raster-mock (log :create-ok nil)
    (ok (%signals-type (lambda () (%render 0)) 'doc-extract-protocol:doc-extract-error))
    (ok (null (find :bitmap-destroy (%names log))))
    (ok (%in-order-p '(:close-page :close-document) log)))
  (with-raster-mock (log :buffer-ok nil)
    (ok (%signals-type (lambda () (%render 0)) 'doc-extract-protocol:doc-extract-error))
    (ok (%in-order-p '(:bitmap-destroy :close-page :close-document) log)))
  (with-raster-mock (log :stride 11)
    (ok (%signals-type (lambda () (%render 0)) 'doc-extract-protocol:doc-extract-error)
        "a stride below 4 × width")
    (ok (%in-order-p '(:bitmap-destroy :close-page :close-document) log)))
  (with-raster-mock (log)
    (ok (eq :thrown (ignore-errors
                     (catch :out
                       (handler-bind ((stack-image:image-limit-exceeded
                                        (lambda (c) (declare (ignore c)) (throw :out :thrown))))
                         (%render 0 :max-pixels 1)))))
        "a non-local exit")
    (ok (%in-order-p '(:close-page :close-document) log))))

(deftest render-sources
  (let ((path (asdf:system-relative-pathname "doc-extract-backend-pdf/tests"
                                             "tests/fixtures/raster.pdf")))
    (with-raster-mock (log)
      (ok (equal '(3 2 :rgba) (ignore-errors (%shape (doc-extract-backend-pdf:render-page path 0)))))
      (ok (equal (list (namestring path) nil) (%entry :load-document log)) "a pathname is opened by name"))
    (with-raster-mock (log)
      (ignore-errors (doc-extract-backend-pdf:render-page *hello-pdf* 0 :password "secret"))
      (ok (equal (list (length *hello-pdf*) "secret") (%entry :load-mem-document log))
          "octets are opened from memory, with the password"))))

(deftest render-without-pdfium
  (%without-pdfium
    (ok (%signals-type (lambda () (%render 0)) 'doc-extract-backend-pdf:pdfium-not-loaded))
    (let ((fallback (stack-image:make-image :width 1 :height 1 :format :gray
                                            :pixels (coerce '(7) '(simple-array (unsigned-byte 8) (*))))))
      (ok (eq fallback (ignore-errors
                        (handler-bind ((doc-extract-backend-pdf:pdfium-not-loaded
                                         (lambda (c) (use-value fallback c))))
                          (%render 0))))
          "USE-VALUE returns the image"))
    (let ((attempts 0))
      (ok (equal '(3 2 :rgba)
                 (ignore-errors
                  (handler-bind ((doc-extract-backend-pdf:pdfium-not-loaded
                                   (lambda (c)
                                     (incf attempts)
                                     (setf doc-extract-backend-pdf:*pdfium-fn-table* (make-raster-mock))
                                     (invoke-restart
                                      (find "RETRY" (compute-restarts c)
                                            :key (lambda (r) (and (restart-name r)
                                                                  (string (restart-name r))))
                                            :test #'equal)))))
                    (%shape (%render 0)))))
          "RETRY starts again")
      (ok (= 1 attempts)))))

(deftest-parametrize render-argument-checks
    ((index args)
     (-1 '())
     (1.5 '())
     (nil '())
     (0 '(:dpi 0))
     (0 '(:dpi -72))
     (0 '(:dpi "72"))
     (0 '(:format :bgra))
     (0 '(:format :cmyk))
     (0 '(:max-pixels 0))
     (0 '(:max-pixels 1.5))
     (0 '(:limits nil))
     (0 '(:password 42)))
  (with-raster-mock (log)
    (ok (%signals-type (lambda () (apply #'doc-extract-backend-pdf:render-page *hello-pdf* index args))
                       'type-error))
    (ok (null (find :load-mem-document (%names log))) "checked before pdfium is called")))

(deftest render-store-value
  (with-raster-mock (log)
    (ok (equal '(6 4 :rgba)
               (ignore-errors
                (handler-bind ((type-error (lambda (c) (store-value 144 c))))
                  (%shape (%call-with #'doc-extract-backend-pdf:render-page *hello-pdf* 0 :dpi 0)))))
        "CHECK-TYPE's STORE-VALUE restart")))

;;; Live: tests/fixtures/raster.pdf through libpdfium ----------------------------

(defparameter *raster-pdf*
  (asdf:system-relative-pathname "doc-extract-backend-pdf/tests" "tests/fixtures/raster.pdf"))

(defmacro with-live-pdfium (&body body)
  `(if (doc-extract-backend-pdf:pdfium-available-p)
       (progn ,@body)
       (skip "libpdfium not present")))

(defun %pixel (image x y)
  (let* ((c (stack-image:channels (stack-image:image-format image)))
         (o (* c (+ (* y (stack-image:image-width image)) x))))
    (coerce (subseq (stack-image:image-pixels image) o (+ o c)) 'list)))

(defun %counts (image)
  "(dark red blue white opaque) pixel counts of an :RGBA IMAGE."
  (let ((px (stack-image:image-pixels image)) (dark 0) (red 0) (blue 0) (white 0) (opaque 0))
    (loop for o from 0 below (length px) by 4
          do (let ((r (aref px o)) (g (aref px (+ o 1))) (b (aref px (+ o 2))) (a (aref px (+ o 3))))
               (when (= a 255) (incf opaque))
               (when (and (< r 64) (< g 64) (< b 64)) (incf dark))
               (when (and (>= r 192) (< g 64) (< b 64)) (incf red))
               (when (and (>= b 192) (< r 64) (< g 64)) (incf blue))
               (when (and (>= r 250) (>= g 250) (>= b 250)) (incf white))))
    (list dark red blue white opaque)))

(defun %within (value expected)
  (<= (* 97/100 expected) value (* 103/100 expected)))

(defun %live (index &rest keys)
  (ignore-errors (apply #'doc-extract-backend-pdf:render-page *raster-pdf* index keys)))

(deftest-parametrize live-render-page-1
    ((dpi size probes counts)
     ;; probes: (x y) in pixels → R G B A. counts: pypdfium2 (dark red blue white).
     (72 '(300 200) '(((80 80) (0 0 0 255)) ((225 155) (255 0 0 255)) ((225 70) (0 0 255 255))
                       ((5 195) (255 255 255 255)) ((290 10) (255 255 255 255)))
      '(8090 4500 3600 43439))
     (150 '(625 417) '(((166 166) (0 0 0 255)) ((468 322) (255 0 0 255)) ((468 145) (0 0 255 255))
                        ((10 406) (255 255 255 255)) ((604 20) (255 255 255 255)))
      '(35546 19740 15792 188745)))
  (with-live-pdfium
    (let ((out (%live 0 :dpi dpi)))
      (ok (and out (equal (append size '(:rgba)) (%shape out))))
      (loop for (xy want) in probes
            do (ok (and out (equal want (%pixel out (first xy) (second xy)))) (format nil "~A" xy)))
      (let ((got (and out (%counts out))))
        (ok (and got (every #'%within (subseq got 0 4) counts)) (format nil "~A ≈ ~A" got counts))
        (ok (and got (= (fifth got) (* (first size) (second size)))) "opaque everywhere")))))

(deftest-parametrize live-render-other-pages
    ((index dpi size probes)
     ;; /Rotate 90: 144 × 72 pt shows as 72 × 144, black on top.
     (1 72 '(72 144) '(((36 36) (0 0 0 255)) ((36 108) (255 255 255 255))))
     (1 150 '(150 300) '(((75 75) (0 0 0 255)) ((75 225) (255 255 255 255))))
     ;; 5 × 5 pt at 36 dpi is 2.5 px: 3 × 3.
     (2 36 '(3 3) '(((0 0) (0 0 0 255))))
     ;; CropBox 100 × 50, black left half.
     (3 72 '(100 50) '(((25 25) (0 0 0 255)) ((75 25) (255 255 255 255)))))
  (with-live-pdfium
    (let ((out (%live index :dpi dpi)))
      (ok (and out (equal (append size '(:rgba)) (%shape out))))
      (loop for (xy want) in probes
            do (ok (and out (equal want (%pixel out (first xy) (second xy)))) (format nil "~A" xy))))))

(deftest live-render-formats-and-sources
  (with-live-pdfium
    (let ((rgba (%live 0)))
      (ok (and rgba (equal '(300 200 :rgba) (%shape rgba))))
      (dolist (format '(:rgb :gray :gray-alpha))
        (let ((out (%live 0 :format format)))
          (ok (and out rgba
                   (equalp (stack-image:image-pixels (stack-image:convert-image rgba format))
                           (stack-image:image-pixels out)))
              (format nil "~A is CONVERT-IMAGE of :RGBA" format))))
      (loop for (label source)
              in (list (list "namestring" (namestring *raster-pdf*))
                       (list "octets"
                             (with-open-file (in *raster-pdf* :element-type '(unsigned-byte 8))
                               (let ((v (make-array (file-length in) :element-type '(unsigned-byte 8))))
                                 (read-sequence v in)
                                 v))))
            do (ok (and rgba (equalp (stack-image:image-pixels rgba)
                                     (ignore-errors (stack-image:image-pixels
                                                     (doc-extract-backend-pdf:render-page source 0)))))
                   (format nil "source: ~A" label))))))

(deftest live-render-limits-and-index
  (with-live-pdfium
    (ok (%signals-type (lambda () (doc-extract-backend-pdf:render-page *raster-pdf* 0 :max-pixels 59999))
                       'stack-image:image-limit-exceeded))
    (ok (equal '(300 200 :rgba) (ignore-errors (%shape (%live 0 :max-pixels 60000)))))
    (let ((c (%condition-of (lambda () (doc-extract-backend-pdf:render-page *raster-pdf* 4)))))
      (ok (and (typep c 'doc-extract-backend-pdf:pdf-page-not-found)
               (= 4 (doc-extract-backend-pdf:pdf-page-not-found-page-count c)))))))
