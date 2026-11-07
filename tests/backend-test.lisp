(in-package #:image-backend-stb/tests)

(deftest registered
  (ok (find-if (lambda (b) (typep b 'stb:stb-backend)) (img:image-backends)))
  (ok (member :png (img:supported-formats)))
  (ok (member :jpeg (img:supported-formats :operation :encode))))

(deftest lossless-fixtures-decode-exactly
  (dolist (e (expected))
    (let ((name (getf e :name)))
      (unless (search ".jpg" name)
        (let* ((image (img:decode-image (fixture name)))
               (want (getf e :format))
               (image (img:convert-image image want)))
          (ok (and (= (img:image-width image) (getf e :width))
                   (= (img:image-height image) (getf e :height))
                   (equalp (img:image-pixels image) (hex-octets (getf e :pixels))))
              name))))))

(deftest sixteen-bit-is-rounded-by-the-protocol
  (let ((i (img:decode-image (fixture "gray16.png"))))
    (ok (equalp (img:image-pixels i) #(0 128 255)))
    (ok (= 16 (img:image-info-depth (img:probe-image (fixture "gray16.png")))))))

(deftest jpeg-is-close-and-oriented
  (let* ((e (find "oriented.jpg" (expected) :key (lambda (x) (getf x :name)) :test #'string=))
         (i (img:decode-image (fixture "oriented.jpg"))))
    (ok (= 6 (img:image-orientation i)))
    (ok (> (psnr (img:image-pixels (img:convert-image i :rgb)) (hex-octets (getf e :pixels))) 25))   ; tiny image, hard edge, 4:2:0: decoders differ
    (let ((upright (img:decode-image (fixture "oriented.jpg") :orient t)))
      (ok (equal (list (img:image-width upright) (img:image-height upright)) '(4 8))))))

(deftest gif-frames-stream-with-delays
  (let ((seq (img:decode-frames (fixture "anim.gif"))))
    (ok (= 3 (length (img:image-sequence-frames seq))))
    (ok (equal (mapcar #'img:image-frame-delay-ms (img:image-sequence-frames seq)) '(100 200 300)))
    (ok (equalp (subseq (img:image-pixels (second (img:image-sequence-frames seq))) 0 4)
                #(0 255 0 255))))
  (ok (signals (img:decode-frames (fixture "anim.gif") :limits (img:make-image-limits :max-frames 2))
               'img:image-limit-exceeded)))

(deftest hostile-input
  ;; The header claims 50000 × 50000: refused before stb allocates.
  (ok (signals (img:decode-image (fixture "bomb.png")) 'img:image-limit-exceeded))
  (ok (signals (img:decode-image (fixture "truncated.png")) 'img:image-decode-error))
  (ok (signals (img:decode-image (make-array 16 :element-type '(unsigned-byte 8) :initial-element 7))
               'img:image-unknown-format))
  ;; TGA / PSD / HDR / PNM are opt-in.
  (let ((tga (img:encode-image (img:decode-image (fixture "rgb.png")) :tga)))
    (ok (signals (img:decode-image tga :format :tga) 'img:image-unsupported-format))
    (let ((img:*enabled-formats* (cons :tga img:+default-enabled-formats+)))
      (ok (= 3 (img:image-width (img:decode-image tga :format :tga)))))))

(deftest encode-round-trips
  (let ((rgba (img:decode-image (fixture "rgba.png"))))
    (dolist (format '(:png :bmp))
      (let ((back (img:decode-image (img:encode-image rgba format))))
        (ok (equalp (img:image-pixels (img:convert-image back :rgba)) (img:image-pixels rgba))
            (string format))))
    (let* ((rgb (img:decode-image (fixture "rgb.png")))
           (jpeg (img:encode-image rgb :jpeg :quality 95)))
      (ok (eq :jpeg (img:sniff-format jpeg)))
      (ok (signals (img:encode-image rgb :jpeg :progressive t) 'img:image-option-ignored))
      (ok (signals (img:encode-image rgb :jpeg :quality 50 :subsampling :444)
                   'img:image-option-ignored)))))

(deftest stb-cap-is-a-second-line
  ;; Even with the protocol's limits off, stb's compiled-in cap (2^15) refuses it.
  (ok (signals (img:decode-image (fixture "bomb.png") :limits (img:make-image-limits :unlimited t))
               'img:image-decode-error))
  (ok (= 3 (img:image-info-width (img:probe-image (fixture "rgb.png"))))))
