(in-package #:image-backend-stb/tests)

;;; Native resize: src/resize.lisp, rules S1–S8, through image-protocol 0.3.0's
;;; BACKEND-RESIZE hook. Results are computed inside OK forms, so a failing
;;; call counts as one failed check and the rest of the test still runs.

(defclass counting-stb (stb:stb-backend)
  ((calls :initform 0 :accessor stb-calls)
   (answers :initform 0 :accessor stb-answers))
  (:documentation "The stb backend, counting its BACKEND-RESIZE calls and the
ones it answered (did not decline). Not registered."))

(defmethod img:backend-resize :around ((backend counting-stb) image width height
                                       &key &allow-other-keys)
  (declare (ignore image width height))
  (incf (stb-calls backend))
  (let ((answer (call-next-method)))
    (when answer (incf (stb-answers backend)))
    answer))

(defparameter *stb* (make-instance 'stb:stb-backend) "An unregistered stb backend.")

(defparameter *formats* '(:gray :gray-alpha :rgb :rgba))

(defun %alpha-p (format) (member format '(:gray-alpha :rgba)))

(defun %image (format w h pixels)
  (img:make-image :width w :height h :format format
                  :pixels (coerce pixels '(simple-array (unsigned-byte 8) (*)))))

(defun %noise (format w h seed)
  "scripts/resize-tolerance.py's noise: image-protocol's parity LCG, alpha
below 32 → 0 and above 223 → 255."
  (let* ((c (img:channels format))
         (px (make-array (* w h c) :element-type '(unsigned-byte 8)))
         (s seed))
    (dotimes (i (length px))
      (setf s (logand (+ (* s 1103515245) 12345) #x7FFFFFFF)
            (aref px i) (logand (ash s -16) #xFF)))
    (when (%alpha-p format)
      (loop for p from (1- c) below (length px) by c
            do (let ((a (aref px p)))
                 (setf (aref px p) (cond ((< a 32) 0) ((> a 223) 255) (t a))))))
    (%image format w h px)))

(defun %smooth (format w h)
  "scripts/resize-tolerance.py's smooth image: a gradient per colour channel,
inverted in a box, and an alpha ramp in the top half."
  (let* ((c (img:channels format))
         (px (make-array (* w h c) :element-type '(unsigned-byte 8))))
    (dotimes (y h)
      (dotimes (x w)
        (dotimes (ch c)
          (setf (aref px (+ (* (+ (* y w) x) c) ch))
                (if (and (%alpha-p format) (= ch (1- c)))
                    (if (< y (floor h 2)) (- 255 (floor (* x 255) (max 1 (1- w)))) 255)
                    (let* ((a (+ 40 (* 30 ch)))
                           (b (- 90 (* 20 ch)))
                           (v (floor (* (+ (* x a) (* y b)) 255)
                                     (max 1 (+ (* (1- w) a) (* (1- h) b))))))
                      (if (and (<= (floor w 4) x) (< x (floor w 2))
                               (<= (floor h 3) y) (< y (floor (* 2 h) 3)))
                          (- 255 v)
                          v)))))))
    (%image format w h px)))

(defun %flat (format w h pixel)
  (%image format w h (loop repeat (* w h) append pixel)))

(defun %pixels-of (image)
  "IMAGE's pixels as a list of per-pixel lists."
  (let ((c (img:channels (img:image-format image))))
    (loop for p from 0 below (length (img:image-pixels image)) by c
          collect (coerce (subseq (img:image-pixels image) p (+ p c)) 'list))))

(defun %difference (a b format)
  "(values max mean) of the sample differences of the octet vectors A and B
in FORMAT, exactly (rationals). Colour samples of alpha formats are compared
premultiplied, c · a / 255; alpha and opaque samples as they are (S8)."
  (let ((c (img:channels format))
        (worst 0) (total 0) (n 0))
    (flet ((add (d) (setf worst (max worst d)) (incf total d) (incf n)))
      (loop for p from 0 below (length a) by c
            do (if (%alpha-p format)
                   (let ((aa (aref a (+ p c -1))) (ab (aref b (+ p c -1))))
                     (dotimes (i (1- c))
                       (add (/ (abs (- (* (aref a (+ p i)) aa) (* (aref b (+ p i)) ab))) 255)))
                     (add (abs (- aa ab))))
                   (dotimes (i c)
                     (add (abs (- (aref a (+ p i)) (aref b (+ p i)))))))))
    (values worst (/ total (max n 1)))))

(defun %pure (image width height &rest keys)
  "image-protocol's own resampler (Pillow 11.3's samples)."
  (apply #'img:resize-image image width height :backend nil keys))

(defun %stb-answer (image width height &key filter reducing-gap linear)
  (img:backend-resize *stb* image width height
                      :filter filter :reducing-gap reducing-gap :linear linear))

(defun %tolerance ()
  "tests/fixtures/resize-tolerance.sexp (scripts/resize-tolerance.py):
→ (values bounds-plist cases)."
  (with-open-file (in (fixture "resize-tolerance.sexp"))
    (with-standard-io-syntax
      (let ((*read-eval* nil) (bounds nil) (cases '()))
        (loop for form = (read in nil in)
              until (eq form in)
              do (ecase (first form)
                   (:bounds (setf bounds (rest form)))
                   (:case (push (rest form) cases))))
        (values bounds (nreverse cases))))))

(deftest stb-resize-abi
  "S4: the native library has stbcl_resize, ABI 2."
  (ok (eql 2 (symbol-value (find-symbol "+ABI+" :image-backend-stb))) "+abi+ is 2")
  (ok (eql 2 (uiop:symbol-call :image-backend-stb '#:%abi)) "libstb-cl reports ABI 2"))

(deftest stb-resize-c-abi-refuses
  "S4: stbcl_resize returns 0 and leaves OUT alone for what it does not serve."
  (flet ((c-resize (in w h comp nw nh filter)
           (let ((out (make-array (max 1 (* (max nw 0) (max nh 0) (max comp 1)))
                                  :element-type '(unsigned-byte 8) :initial-element 7)))
             (cffi:with-pointer-to-vector-data (pin in)
               (cffi:with-pointer-to-vector-data (pout out)
                 (list (uiop:symbol-call :image-backend-stb '#:%resize pin w h comp pout nw nh filter)
                       out))))))
    (let ((in (img:image-pixels (%noise :rgba 9 7 3))))
      (ok (let ((r (c-resize in 9 7 4 4 3 4)))
            (and (eql 1 (first r)) (notevery (lambda (v) (= v 7)) (second r))))
          "Catmull-Rom (4): 1, and OUT written")
      (ok (eql 1 (first (c-resize in 9 7 4 4 3 2))) "triangle (2): 1")
      (dolist (bad '((9 7 4 4 3 1 "box (1)") (9 7 4 4 3 6 "point (6)") (9 7 4 4 3 99 "filter 99")
                     (9 7 5 4 3 4 "5 channels") (9 7 0 4 3 4 "0 channels")
                     (9 7 4 0 3 4 "width 0") (9 7 4 4 -1 4 "height -1") (0 7 4 4 3 4 "input width 0")))
        (destructuring-bind (w h comp nw nh filter what) bad
          (ok (let ((r (c-resize in w h comp nw nh filter)))
                (and (eql 0 (first r)) (every (lambda (v) (= v 7)) (second r))))
              (format nil "~a: 0, OUT untouched" what)))))))

(deftest stb-resize-serves-bilinear-and-bicubic
  "S2, S6: an answer for :bilinear and :bicubic, in every format, gap or not."
  (dolist (format *formats*)
    (dolist (filter '(:bilinear :bicubic))
      (dolist (size '((9 7 4 3) (4 3 11 9)))
        (destructuring-bind (w h ow oh) size
          (let* ((src (%noise format w h 11))
                 (before (copy-seq (img:image-pixels src))))
            (ok (let ((r (%stb-answer src ow oh :filter filter)))
                  (and (img:image-p r) (= ow (img:image-width r)) (= oh (img:image-height r))
                       (eq format (img:image-format r)) (eql 8 (img:image-depth r))
                       (= (* ow oh (img:channels format)) (length (img:image-pixels r)))
                       (not (eq (img:image-pixels r) (img:image-pixels src)))
                       (equalp before (img:image-pixels src))))
                (format nil "~(~a ~a~) ~d × ~d → ~d × ~d: a fresh image, IMAGE unchanged"
                        format filter w h ow oh)))))))
  (ok (img:image-p (%stb-answer (%noise :rgb 40 30 3) 9 7 :filter :bicubic :reducing-gap 2))
      "a reducing gap is accepted")
  (ok (let ((src (%noise :rgb 40 30 3)))
        (equalp (img:image-pixels (%stb-answer src 9 7 :filter :bicubic :reducing-gap 2))
                (img:image-pixels (%stb-answer src 9 7 :filter :bicubic))))
      "and not applied"))

(deftest stb-resize-declines-the-rest
  "S2: NIL for :lanczos3, :box, :nearest and linear light."
  (dolist (format *formats*)
    (let ((src (%noise format 9 7 13)))
      (dolist (keys '((:filter :lanczos3) (:filter :box) (:filter :nearest)
                      (:filter :bicubic :linear t) (:filter :bilinear :linear t)))
        (ok (null (apply #'%stb-answer src 4 3 keys))
            (format nil "~(~a~) ~s: declined" format keys))))))

(deftest stb-resize-through-the-protocol
  "S1: opt-in through :backend or *resize-backends*; the protocol keeps the metadata."
  (let ((src (%noise :rgb 40 20 17)))
    (setf (img:image-orientation src) 6 (img:image-gamma src) 0.45)
    (let ((r nil))
      (ok (setf r (img:resize-image src 9 7 :filter :bicubic :backend *stb*)) "resizes")
      (ok (and r (equalp (img:image-pixels r)
                         (img:image-pixels (%stb-answer src 9 7 :filter :bicubic))))
          "the backend's pixels")
      (ok (and r (eql 6 (img:image-orientation r)) (eql 0.45 (img:image-gamma r)))
          "IMAGE's metadata"))
    (ok (let ((r (img:resize-image src 9 7 :backend *stb*)))
          (equalp (img:image-pixels r) (img:image-pixels (%pure src 9 7))))
        "the default :lanczos3 is declined, so the protocol's resampler runs")
    (ok (let ((img:*resize-backends* (list *stb*)))
          (equalp (img:image-pixels (img:thumbnail src 10 10 :filter :bilinear))
                  (img:image-pixels (%stb-answer src 10 5 :filter :bilinear :reducing-gap 2))))
        "thumbnail through *resize-backends*")
    (ok (equalp (img:image-pixels (img:resize-image src 9 7 :filter :bicubic))
                (img:image-pixels (%pure src 9 7 :filter :bicubic)))
        "loading the backend registers it for codecs, not for resizing")))

(deftest stb-resize-flat-and-transparent
  "Flat images stay flat; a transparent pixel adds no colour."
  (dolist (case '((:gray (90)) (:gray-alpha (90 128)) (:rgb (10 128 250)) (:rgba (30 60 90 128))))
    (destructuring-bind (format pixel) case
      (dolist (filter '(:bilinear :bicubic))
        (dolist (size '((9 7 4 3) (4 3 11 9)))
          (destructuring-bind (w h ow oh) size
            (ok (let ((r (%stb-answer (%flat format w h pixel) ow oh :filter filter)))
                  (every (lambda (p) (equal p pixel)) (%pixels-of r)))
                (format nil "~(~a ~a~) ~d × ~d → ~d × ~d stays ~s" format filter w h ow oh pixel)))))))
  (dolist (filter '(:bilinear :bicubic))
    (dolist (size '((1 1) (3 1) (5 2)))
      (destructuring-bind (ow oh) size
        (ok (let ((r (%stb-answer (%image :rgba 2 1 '(255 0 0 255  0 255 0 0)) ow oh :filter filter)))
              (every (lambda (p) (or (zerop (fourth p)) (equal (subseq p 0 3) '(255 0 0))))
                     (%pixels-of r)))
            (format nil "rgba ~(~a~) → ~d × ~d: no green where alpha > 0" filter ow oh))
        (ok (let ((r (%stb-answer (%image :gray-alpha 2 1 '(200 255  0 0)) ow oh :filter filter)))
              (every (lambda (p) (or (zerop (second p)) (= 200 (first p)))) (%pixels-of r)))
            (format nil "gray-alpha ~(~a~) → ~d × ~d: 200 where alpha > 0" filter ow oh))))))

(deftest stb-resize-matches-its-filter
  "S3: each answer is nearer the protocol's result for its own filter than for the other."
  (dolist (size '((13 11 40 29) (64 48 21 17)))
    (destructuring-bind (w h ow oh) size
      (let ((src (%noise :gray w h 5)))
        (dolist (pair '((:bicubic :bilinear) (:bilinear :bicubic)))
          (destructuring-bind (own other) pair
            (ok (let ((r (img:image-pixels (%stb-answer src ow oh :filter own))))
                  (< (nth-value 1 (%difference r (img:image-pixels (%pure src ow oh :filter own)) :gray))
                     (nth-value 1 (%difference r (img:image-pixels (%pure src ow oh :filter other)) :gray))))
                (format nil "~(~a~) ~d × ~d → ~d × ~d: nearer ~(~a~) than ~(~a~)"
                        own w h ow oh own other))))))))

(deftest stb-resize-checks-come-first
  "image-protocol R2: limits and arguments are refused before the native call."
  (let ((backend (make-instance 'counting-stb))
        (src (%noise :rgb 9 7 19)))
    (let ((img:*image-limits* (img:make-image-limits :max-width 10)))
      (ok (signals (img:resize-image src 11 3 :filter :bicubic :backend backend)
                   'img:image-limit-exceeded)
          "the output size against *image-limits*"))
    (ok (signals (img:resize-image src 0 3 :filter :bicubic :backend backend)
                 'img:image-invalid-argument)
        "a bad width")
    (ok (zerop (stb-calls backend)) "no call so far")
    (ok (img:image-p (img:resize-image src 4 3 :filter :bicubic :backend backend)) "then a resize")
    (ok (= 1 (stb-calls backend)) "one call")))

(deftest stb-resize-close-to-the-protocol
  "S8: within the measured bounds of the protocol's result (Pillow 11.3's samples)
   in every case of tests/fixtures/resize-tolerance.sexp, edges included."
  (multiple-value-bind (bounds cases) (%tolerance)
    (let ((max-bound (getf bounds :max))
          (mean-bound (getf bounds :mean))
          (backend (make-instance 'counting-stb))
          (groups '()))
      (ok (and (realp max-bound) (realp mean-bound) (= 144 (length cases)))
          (format nil "bounds max ~a, mean ~a; ~d cases" max-bound mean-bound (length cases)))
      (dolist (case cases)
        (destructuring-bind (kind format w h ow oh filter gap seed &rest measured) case
          (declare (ignore measured))
          (let* ((src (ecase kind (:noise (%noise format w h seed)) (:smooth (%smooth format w h))))
                 (key (list kind filter))
                 (group (or (assoc key groups :test #'equal)
                            (car (push (list key 0 0 '()) groups)))))
            (handler-case
                (multiple-value-bind (worst mean)
                    (%difference (img:image-pixels (img:resize-image src ow oh :filter filter
                                                                               :reducing-gap gap
                                                                               :backend backend))
                                 (img:image-pixels (%pure src ow oh :filter filter :reducing-gap gap))
                                 format)
                  (setf (second group) (max (second group) worst)
                        (third group) (max (third group) mean))
                  (unless (and (<= worst max-bound) (<= mean mean-bound))
                    (push (list format w h ow oh gap :max (float worst) :mean (float mean))
                          (fourth group))))
              (error (e)
                (push (list format w h ow oh gap :error (princ-to-string e)) (fourth group)))))))
      (dolist (group (reverse groups))
        (destructuring-bind ((kind filter) worst mean breaches) group
          (ok (null breaches)
              (format nil "~(~a ~a~): max ~,2f, mean ~,3f~@[; ~d over the bounds, first ~s~]"
                      kind filter worst mean (and breaches (length breaches))
                      (first (last breaches))))))
      (ok (= (length cases) (stb-answers backend)) "the backend answered every case"))))
