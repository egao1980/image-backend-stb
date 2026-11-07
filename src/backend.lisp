(in-package #:image-backend-stb)

(defconstant +abi+ 1)

(cffi:defcfun ("stbcl_abi" %abi) :int)
(cffi:defcfun ("stbcl_failure_reason" %failure-reason) :string)
(cffi:defcfun ("stbcl_free" %free) :void (p :pointer))
(cffi:defcfun ("stbcl_info" %stbcl-info) :int
  (data :pointer) (len :int) (w :pointer) (h :pointer) (comp :pointer) (is16 :pointer))
(cffi:defcfun ("stbcl_load" %load) :pointer
  (data :pointer) (len :int) (want16 :int) (w :pointer) (h :pointer) (comp :pointer))
(cffi:defcfun ("stbcl_gif_open" %gif-open) :pointer (data :pointer) (len :int))
(cffi:defcfun ("stbcl_gif_next" %gif-next) :int
  (gif :pointer) (w :pointer) (h :pointer) (delay :pointer) (pixels :pointer))
(cffi:defcfun ("stbcl_gif_close" %gif-close) :void (gif :pointer))
(cffi:defcfun ("stbcl_encode" %encode) :pointer
  (format :int) (w :int) (h :int) (comp :int) (pixels :pointer) (level :int) (quality :int)
  (out-len :pointer))
(cffi:defcfun ("stbcl_free_buffer" %free-buffer) :void (p :pointer))

(unless (= (%abi) +abi+)
  (error 'img:image-native-unavailable
         :cause (format nil "libstb-cl ABI ~A, expected ~A" (%abi) +abi+)))

(defclass stb-backend (img:image-backend) ()
  (:documentation "stb_image / stb_image_write, vendored with Fedora's patches."))

(defparameter +decode+ '(:png :jpeg :gif :bmp :psd :hdr :pnm :tga))
(defparameter +encode+ '((:png . 0) (:jpeg . 1) (:bmp . 2) (:tga . 3)))

(defmethod img:backend-formats ((b stb-backend))
  (append (loop for f in +decode+ collect (list f :decode 50))
          (loop for (f . nil) in +encode+ collect (list f :encode 50))))

(defun %format-of (comp) (ecase comp (1 :gray) (2 :gray-alpha) (3 :rgb) (4 :rgba)))

(defmacro with-input ((ptr len octets) &body body)
  `(let ((,len (length ,octets)))
     (cffi:with-pointer-to-vector-data (,ptr ,octets) ,@body)))

(defun %decode-error (format backend)
  (error 'img:image-corrupt :format format :backend backend :cause (%failure-reason)))

(defun %info (format octets backend)
  (with-input (p n octets)
    (cffi:with-foreign-objects ((w :int) (h :int) (c :int) (is16 :int))
      (when (zerop (%stbcl-info p n w h c is16))
        (%decode-error format backend))
      (values (cffi:mem-ref w :int) (cffi:mem-ref h :int) (cffi:mem-ref c :int)
              (plusp (cffi:mem-ref is16 :int))))))

(defmethod img:backend-probe ((b stb-backend) format octets)
  (multiple-value-bind (w h c is16) (%info format octets b)
    (img:make-image-info :format format :width w :height h :pixel-format (%format-of c)
                         :depth (if is16 16 8)
                         :animated-p (and (eq format :gif) t))))

(defun %copy-out (pointer count)
  (let ((out (make-array count :element-type '(unsigned-byte 8))))
    (dotimes (i count out) (setf (aref out i) (cffi:mem-aref pointer :uint8 i)))))

(defun %decode-one (b format octets limits)
  (multiple-value-bind (w h c is16) (%info format octets b)
    ;; Limits before stb allocates anything.
    (img:check-dimensions w h c :limits limits :format format)
    (with-input (p n octets)
      (cffi:with-foreign-objects ((pw :int) (ph :int) (pc :int))
        (let ((pixels (%load p n (if is16 1 0) pw ph pc)))
          (when (cffi:null-pointer-p pixels) (%decode-error format b))
          (unwind-protect
               (let* ((w (cffi:mem-ref pw :int)) (h (cffi:mem-ref ph :int))
                      (c (cffi:mem-ref pc :int)) (count (* w h c)))
                 (img:make-image
                  :width w :height h :format (%format-of c)
                  :pixels (if is16
                              (let ((samples (make-array count)))
                                (dotimes (i count) (setf (aref samples i) (cffi:mem-aref pixels :uint16 i)))
                                (img:depth-16-to-8 samples))
                              (%copy-out pixels count))))
            (%free pixels)))))))

(defun %decode-gif (b octets limits)
  (multiple-value-bind (w h) (%info :gif octets b)
    (img:check-dimensions w h 4 :limits limits :format :gif))
  (with-input (p n octets)
    (let ((gif (%gif-open p n)))
      (when (cffi:null-pointer-p gif) (%decode-error :gif b))
      (unwind-protect
           (cffi:with-foreign-objects ((pw :int) (ph :int) (pd :int) (px :pointer))
             (let ((frames '()) (count 0))
               (loop
                 (let ((r (%gif-next gif pw ph pd px)))
                   (cond ((zerop r) (return))
                         ((minusp r) (%decode-error :gif b)))
                   (incf count)
                   (let ((fw (cffi:mem-ref pw :int)) (fh (cffi:mem-ref ph :int)))
                     ;; Budget per frame: stb would have held them all at once.
                     (img:check-dimensions fw fh 4 :limits limits :format :gif :frames count)
                     (push (img:make-image-frame
                            :width fw :height fh :format :rgba
                            :pixels (%copy-out (cffi:mem-ref px :pointer) (* fw fh 4))
                            :delay-ms (max 0 (cffi:mem-ref pd :int)))
                           frames))))
               (img:make-image-sequence :frames (nreverse frames))))
        (%gif-close gif)))))

(defmethod img:backend-decode ((b stb-backend) format octets &key limits frames)
  (let ((limits (or limits img:*image-limits*)))
    (cond ((eq format :gif)
           (let ((seq (%decode-gif b octets limits)))
             (if frames seq (first (img:image-sequence-frames seq)))))
          (t (let ((image (%decode-one b format octets limits)))
               (if frames (img:make-image-sequence :frames (list image)) image))))))

(defmethod img:backend-encode ((b stb-backend) image format
                               &key quality compression-level subsampling progressive
                                 loop-count backend-options)
  (declare (ignore backend-options loop-count))
  (let ((code (cdr (assoc format +encode+))))
    (unless code (error 'img:image-unsupported-format :format format :operation :encode))
    (when progressive (img:ignore-option b format :progressive))
    ;; stb subsamples JPEG chroma (4:2:0) at quality <= 90 and never otherwise.
    (when (and (eq format :jpeg) subsampling
               (not (eq subsampling (if (<= (or quality 90) 90) :420 :444))))
      (img:ignore-option b format :subsampling))
    (let* ((pixels (img:image-pixels image))
           (c (img:channels (img:image-format image))))
      (cffi:with-pointer-to-vector-data (p pixels)
        (cffi:with-foreign-object (len :size)
          (let ((out (%encode code (img:image-width image) (img:image-height image) c p
                              (or compression-level 6) (or quality 90) len)))
            (when (cffi:null-pointer-p out)
              (error 'img:image-encode-error :format format :backend b))
            (unwind-protect (%copy-out out (cffi:mem-ref len :size))
              (%free-buffer out))))))))

(img:register-image-backend (make-instance 'stb-backend))
