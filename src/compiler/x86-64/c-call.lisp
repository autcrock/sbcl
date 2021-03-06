;;;; the VOPs and other necessary machine specific support
;;;; routines for call-out to C

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

;; The MOVE-ARG vop is going to store args on the stack for
;; call-out. These tn's will be used for that. move-arg is normally
;; used for things going down the stack but C wants to have args
;; indexed in the positive direction.

(defun my-make-wired-tn (prim-type-name sc-name offset)
  (make-wired-tn (primitive-type-or-lose prim-type-name)
                 (sc-number-or-lose sc-name)
                 offset))

(defstruct (arg-state (:copier nil))
  (register-args 0)
  (xmm-args 0)
  (stack-frame-size 0))

(defconstant max-int-args #.(length *c-call-register-arg-offsets*))
(defconstant max-xmm-args #!+win32 4 #!-win32 8)

(defun int-arg (state prim-type reg-sc stack-sc)
  (let ((reg-args (max (arg-state-register-args state)
                       #!+win32 (arg-state-xmm-args state))))
    (cond ((< reg-args max-int-args)
           (setf (arg-state-register-args state) (1+ reg-args))
           (my-make-wired-tn prim-type reg-sc
                             (nth reg-args *c-call-register-arg-offsets*)))
          (t
           (let ((frame-size (arg-state-stack-frame-size state)))
             (setf (arg-state-stack-frame-size state) (1+ frame-size))
             (my-make-wired-tn prim-type stack-sc frame-size))))))

(define-alien-type-method (integer :arg-tn) (type state)
  (if (alien-integer-type-signed type)
      (int-arg state 'signed-byte-64 'signed-reg 'signed-stack)
      (int-arg state 'unsigned-byte-64 'unsigned-reg 'unsigned-stack)))

(define-alien-type-method (system-area-pointer :arg-tn) (type state)
  (declare (ignore type))
  (int-arg state 'system-area-pointer 'sap-reg 'sap-stack))

(defun float-arg (state prim-type reg-sc stack-sc)
  (let ((xmm-args (max (arg-state-xmm-args state)
                        #!+win32 (arg-state-register-args state))))
    (cond ((< xmm-args max-xmm-args)
           (setf (arg-state-xmm-args state) (1+ xmm-args))
           (my-make-wired-tn prim-type reg-sc
                             (nth xmm-args *float-regs*)))
          (t
           (let ((frame-size (arg-state-stack-frame-size state)))
             (setf (arg-state-stack-frame-size state) (1+ frame-size))
             (my-make-wired-tn prim-type stack-sc frame-size))))))

(define-alien-type-method (double-float :arg-tn) (type state)
  (declare (ignore type))
  (float-arg state 'double-float 'double-reg 'double-stack))

(define-alien-type-method (single-float :arg-tn) (type state)
  (declare (ignore type))
  (float-arg state 'single-float 'single-reg 'single-stack))

(defstruct (result-state (:copier nil))
  (num-results 0))

(defun result-reg-offset (slot)
  (ecase slot
    (0 eax-offset)
    (1 edx-offset)))

(define-alien-type-method (integer :result-tn) (type state)
  (let ((num-results (result-state-num-results state)))
    (setf (result-state-num-results state) (1+ num-results))
    (multiple-value-bind (ptype reg-sc)
        (if (alien-integer-type-signed type)
            (values 'signed-byte-64 'signed-reg)
            (values 'unsigned-byte-64 'unsigned-reg))
      (my-make-wired-tn ptype reg-sc (result-reg-offset num-results)))))

(define-alien-type-method (integer :naturalize-gen) (type alien)
  (if (<= (alien-type-bits type) 32)
      (if (alien-integer-type-signed type)
          `(sign-extend ,alien ,(alien-type-bits type))
          `(logand ,alien ,(1- (ash 1 (alien-type-bits type)))))
      alien))

(define-alien-type-method (system-area-pointer :result-tn) (type state)
  (declare (ignore type))
  (let ((num-results (result-state-num-results state)))
    (setf (result-state-num-results state) (1+ num-results))
    (my-make-wired-tn 'system-area-pointer 'sap-reg
                      (result-reg-offset num-results))))

(define-alien-type-method (double-float :result-tn) (type state)
  (declare (ignore type))
  (let ((num-results (result-state-num-results state)))
    (setf (result-state-num-results state) (1+ num-results))
    (my-make-wired-tn 'double-float 'double-reg num-results)))

(define-alien-type-method (single-float :result-tn) (type state)
  (declare (ignore type))
  (let ((num-results (result-state-num-results state)))
    (setf (result-state-num-results state) (1+ num-results))
    (my-make-wired-tn 'single-float 'single-reg num-results)))

(define-alien-type-method (values :result-tn) (type state)
  (let ((values (alien-values-type-values type)))
    (when (> (length values) 2)
      (error "Too many result values from c-call."))
    (mapcar (lambda (type)
              (invoke-alien-type-method :result-tn type state))
            values)))

(defun make-call-out-tns (type)
  (let ((arg-state (make-arg-state)))
    (collect ((arg-tns))
      (dolist (arg-type (alien-fun-type-arg-types type))
        (arg-tns (invoke-alien-type-method :arg-tn arg-type arg-state)))
      (values (my-make-wired-tn 'positive-fixnum 'any-reg esp-offset)
              (* (arg-state-stack-frame-size arg-state) n-word-bytes)
              (arg-tns)
              (invoke-alien-type-method :result-tn
                                        (alien-fun-type-result-type type)
                                        (make-result-state))))))


(deftransform %alien-funcall ((function type &rest args) * * :node node)
  (aver (sb!c::constant-lvar-p type))
  (let* ((type (sb!c::lvar-value type))
         (env (sb!c::node-lexenv node))
         (arg-types (alien-fun-type-arg-types type))
         (result-type (alien-fun-type-result-type type)))
    (aver (= (length arg-types) (length args)))
    (if (or (some #'(lambda (type)
                      (and (alien-integer-type-p type)
                           (> (sb!alien::alien-integer-type-bits type) 64)))
                  arg-types)
            (and (alien-integer-type-p result-type)
                 (> (sb!alien::alien-integer-type-bits result-type) 64)))
        (collect ((new-args) (lambda-vars) (new-arg-types))
          (dolist (type arg-types)
            (let ((arg (gensym)))
              (lambda-vars arg)
              (cond ((and (alien-integer-type-p type)
                          (> (sb!alien::alien-integer-type-bits type) 64))
                     ;; CLH: FIXME! This should really be
                     ;; #xffffffffffffffff. nyef says: "Passing
                     ;; 128-bit integers to ALIEN functions on x86-64
                     ;; believed to be broken."
                     (new-args `(logand ,arg #xffffffff))
                     (new-args `(ash ,arg -64))
                     (new-arg-types (parse-alien-type '(unsigned 64) env))
                     (if (alien-integer-type-signed type)
                         (new-arg-types (parse-alien-type '(signed 64) env))
                         (new-arg-types (parse-alien-type '(unsigned 64) env))))
                    (t
                     (new-args arg)
                     (new-arg-types type)))))
          (cond ((and (alien-integer-type-p result-type)
                      (> (sb!alien::alien-integer-type-bits result-type) 64))
                 (let ((new-result-type
                        (let ((sb!alien::*values-type-okay* t))
                          (parse-alien-type
                           (if (alien-integer-type-signed result-type)
                               '(values (unsigned 64) (signed 64))
                               '(values (unsigned 64) (unsigned 64)))
                           env))))
                   `(lambda (function type ,@(lambda-vars))
                      (declare (ignore type))
                      (multiple-value-bind (low high)
                          (%alien-funcall function
                                          ',(make-alien-fun-type
                                             :arg-types (new-arg-types)
                                             :result-type new-result-type)
                                          ,@(new-args))
                        (logior low (ash high 64))))))
                (t
                 `(lambda (function type ,@(lambda-vars))
                    (declare (ignore type))
                    (%alien-funcall function
                                    ',(make-alien-fun-type
                                       :arg-types (new-arg-types)
                                       :result-type result-type)
                                    ,@(new-args))))))
        (sb!c::give-up-ir1-transform))))

;;; The ABI is vague about how signed sub-word integer return values
;;; are handled, but since gcc versions >=4.3 no longer do sign
;;; extension in the callee, we need to do it in the caller.  FIXME:
;;; If the value to be extended is known to already be of the target
;;; type at compile time, we can (and should) elide the extension.
(defknown sign-extend ((signed-byte 64) t) fixnum
    (foldable flushable movable))

(define-vop (sign-extend)
  (:translate sign-extend)
  (:policy :fast-safe)
  (:args (val :scs (signed-reg)))
  (:arg-types signed-num (:constant fixnum))
  (:info size)
  (:results (res :scs (signed-reg)))
  (:result-types fixnum)
  (:generator 1
   (inst movsxd res
         (make-random-tn :kind :normal
                         :sc (sc-or-lose (ecase size
                                           (8 'byte-reg)
                                           (16 'word-reg)
                                           (32 'dword-reg)))
                         :offset (tn-offset val)))))

#-sb-xc-host
(defun sign-extend (x size)
  (declare (type (signed-byte 64) x))
  (ecase size
    (8 (sign-extend x size))
    (16 (sign-extend x size))
    (32 (sign-extend x size))))

#+sb-xc-host
(defun sign-extend (x size)
  (if (logbitp (1- size) x)
      (dpb x (byte size 0) -1)
      x))

(define-vop (foreign-symbol-sap)
  (:translate foreign-symbol-sap)
  (:policy :fast-safe)
  (:args)
  (:arg-types (:constant simple-string))
  (:info foreign-symbol)
  (:results (res :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:generator 2
   (inst mov res (make-fixup foreign-symbol :foreign))))

#!+linkage-table
(define-vop (foreign-symbol-dataref-sap)
  (:translate foreign-symbol-dataref-sap)
  (:policy :fast-safe)
  (:args)
  (:arg-types (:constant simple-string))
  (:info foreign-symbol)
  (:results (res :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:generator 2
   (inst mov res (make-fixup foreign-symbol :foreign-dataref))))

(define-vop (call-out)
  (:args (function :scs (sap-reg)
                   :target rbx)
         (args :more t))
  (:results (results :more t))
  ;; RBX is used to first load the address, allowing the debugger to
  ;; determine which alien was accessed in case it's undefined.
  (:temporary (:sc sap-reg :offset rbx-offset :from (:argument 0)) rbx)
  (:temporary (:sc unsigned-reg :offset rax-offset :to :result) rax)
  ;; For safepoint builds: Force values of non-volatiles to the stack.
  ;; These are the callee-saved registers in the native ABI, but
  ;; safepoint-based GC needs to see all Lisp values on the stack.  Note
  ;; that R12-R15 are non-volatile registers, but there is no need to
  ;; spill R12 because it is our thread-base-tn.  RDI and RSI are
  ;; non-volatile on Windows, but argument passing registers on other
  ;; platforms.
  #!+sb-safepoint (:temporary (:sc unsigned-reg :offset r13-offset) r13)
  #!+sb-safepoint (:temporary (:sc unsigned-reg :offset r14-offset) r14)
  #!+sb-safepoint (:temporary (:sc unsigned-reg :offset r15-offset) r15)
  #!+(and sb-safepoint win32) (:temporary
                               (:sc unsigned-reg :offset rdi-offset) rdi)
  #!+(and sb-safepoint win32) (:temporary
                               (:sc unsigned-reg :offset rsi-offset) rsi)
  (:ignore results
           #!+(and sb-safepoint win32) rdi
           #!+(and sb-safepoint win32) rsi
           #!+win32 args
           #!+win32 rax
           #!+sb-safepoint r15
           #!+sb-safepoint r13)
  (:vop-var vop)
  (:save-p t)
  (:generator 0
    #!+sb-safepoint
    (progn
      ;; Current PC - don't rely on function to keep it in a form that
      ;; GC understands
      (let ((label (gen-label)))
        (inst lea r14 (make-fixup nil :code-object label))
        (emit-label label)))
    #!-win32
    ;; ABI: AL contains amount of arguments passed in XMM registers
    ;; for vararg calls.
    (move-immediate rax
                    (loop for tn-ref = args then (tn-ref-across tn-ref)
                          while tn-ref
                          count (eq (sb-name (sc-sb (tn-sc (tn-ref-tn tn-ref))))
                                    'float-registers)))
    #!+win32 (inst sub rsp-tn #x20) ;MS_ABI: shadow zone
    #!+sb-safepoint
    (progn                 ;Store SP and PC in thread struct
      (storew rsp-tn thread-base-tn thread-saved-csp-offset)
      (storew r14 thread-base-tn thread-pc-around-foreign-call-slot))
    (move rbx function)
    (inst call rbx)
    #!+win32 (inst add rsp-tn #x20) ;MS_ABI: remove shadow space
    #!+sb-safepoint
    (progn
      ;; Zeroing out
      (inst xor r14 r14)
      ;; Zero PC storage place. NB. CSP-then-PC: same sequence on
      ;; entry/exit, is actually corrent.
      (storew r14 thread-base-tn thread-saved-csp-offset)
      (storew r14 thread-base-tn thread-pc-around-foreign-call-slot))
    ;; To give the debugger a clue. XX not really internal-error?
    (note-this-location vop :internal-error)))

(define-vop (alloc-number-stack-space)
  (:info amount)
  (:results (result :scs (sap-reg any-reg)))
  (:result-types system-area-pointer)
  (:generator 0
    (aver (location= result rsp-tn))
    (unless (zerop amount)
      (let ((delta (logandc2 (+ amount 7) 7)))
        (inst sub rsp-tn delta)))
    ;; C stack must be 16 byte aligned
    (inst and rsp-tn -16)
    (move result rsp-tn)))

(macrolet ((alien-stack-ptr ()
             #!+sb-thread '(symbol-known-tls-cell '*alien-stack-pointer*)
             #!-sb-thread '(static-symbol-value-ea '*alien-stack-pointer*)))
  (define-vop (alloc-alien-stack-space)
    (:info amount)
    (:results (result :scs (sap-reg any-reg)))
    (:result-types system-area-pointer)
    (:generator 0
      (aver (not (location= result rsp-tn)))
      (unless (zerop amount)
        (let ((delta (logandc2 (+ amount 7) 7)))
          (inst sub (alien-stack-ptr) delta)))
      (inst mov result (alien-stack-ptr)))))

;;; not strictly part of the c-call convention, but needed for the
;;; WITH-PINNED-OBJECTS macro used for "locking down" lisp objects so
;;; that GC won't move them while foreign functions go to work.
(define-vop (touch-object)
  (:translate touch-object)
  (:args (object))
  (:ignore object)
  (:policy :fast-safe)
  (:arg-types t)
  (:generator 0))

;;; Callbacks

#-sb-xc-host
(defun alien-callback-accessor-form (type sp offset)
  `(deref (sap-alien (sap+ ,sp ,offset) (* ,type))))

#-sb-xc-host
(defun alien-callback-assembler-wrapper (index result-type argument-types)
  (labels ((make-tn-maker (sc-name)
             (lambda (offset)
               (make-random-tn :kind :normal
                               :sc (sc-or-lose sc-name)
                               :offset offset))))
    (let* ((segment (make-segment))
           (rax rax-tn)
           #!+(or win32 (not sb-thread)) (rcx rcx-tn)
           #!-(and win32 sb-thread) (rdi rdi-tn)
           #!-(and win32 sb-thread) (rsi rsi-tn)
           (rdx rdx-tn)
           (rbp rbp-tn)
           (rsp rsp-tn)
           #!+(and win32 sb-thread) (r8 r8-tn)
           (xmm0 float0-tn)
           ([rsp] (make-ea :qword :base rsp :disp 0))
           ;; How many arguments have been copied
           (arg-count 0)
           ;; How many arguments have been copied from the stack
           (stack-argument-count #!-win32 0 #!+win32 4)
           (gprs (mapcar (make-tn-maker 'any-reg) *c-call-register-arg-offsets*))
           (fprs (mapcar (make-tn-maker 'double-reg)
                         ;; Only 8 first XMM registers are used for
                         ;; passing arguments
                         (subseq *float-regs* 0 #!-win32 8 #!+win32 4))))
      (assemble (segment)
        ;; Make room on the stack for arguments.
        (when argument-types
          (inst sub rsp (* n-word-bytes (length argument-types))))
        ;; Copy arguments from registers to stack
        (dolist (type argument-types)
          (let ((integerp (not (alien-float-type-p type)))
                ;; A TN pointing to the stack location where the
                ;; current argument should be stored for the purposes
                ;; of ENTER-ALIEN-CALLBACK.
                (target-tn (make-ea :qword :base rsp
                                   :disp (* arg-count
                                            n-word-bytes)))
                ;; A TN pointing to the stack location that contains
                ;; the next argument passed on the stack.
                (stack-arg-tn (make-ea :qword :base rsp
                                       :disp (* (+ 1
                                                   (length argument-types)
                                                   stack-argument-count)
                                                n-word-bytes))))
            (incf arg-count)
            (cond (integerp
                   (let ((gpr (pop gprs)))
                     #!+win32 (pop fprs)
                     ;; Argument not in register, copy it from the old
                     ;; stack location to a temporary register.
                     (unless gpr
                       (incf stack-argument-count)
                       (setf gpr temp-reg-tn)
                       (inst mov gpr stack-arg-tn))
                     ;; Copy from either argument register or temporary
                     ;; register to target.
                     (inst mov target-tn gpr)))
                  ((or (alien-single-float-type-p type)
                       (alien-double-float-type-p type))
                   (let ((fpr (pop fprs)))
                     #!+win32 (pop gprs)
                     (cond (fpr
                            ;; Copy from float register to target location.
                            (inst movq target-tn fpr))
                           (t
                            ;; Not in float register. Copy from stack to
                            ;; temporary (general purpose) register, and
                            ;; from there to the target location.
                            (incf stack-argument-count)
                            (inst mov temp-reg-tn stack-arg-tn)
                            (inst mov target-tn temp-reg-tn)))))
                  (t
                   (bug "Unknown alien floating point type: ~S" type)))))

        #!-sb-thread
        (progn
          ;; arg0 to FUNCALL3 (function)
          (inst mov rdi (make-ea :qword :disp (static-fdefn-fun-addr 'enter-alien-callback)))
          ;; arg0 to ENTER-ALIEN-CALLBACK (trampoline index)
          (inst mov rsi (fixnumize index))
          ;; arg1 to ENTER-ALIEN-CALLBACK (pointer to argument vector)
          (inst mov rdx rsp)
          ;; add room on stack for return value
          (inst sub rsp (if (evenp arg-count)
                            (* n-word-bytes 2)
                            n-word-bytes))
          ;; arg2 to ENTER-ALIEN-CALLBACK (pointer to return value)
          (inst mov rcx rsp)

          ;; Make new frame
          (inst push rbp)
          (inst mov  rbp rsp)

          ;; Call
          (inst mov  rax (foreign-symbol-address "funcall3"))
          (inst call rax)

          ;; Back! Restore frame
          (inst mov rsp rbp)
          (inst pop rbp))

        #!+sb-thread
        (progn
          ;; arg0 to ENTER-ALIEN-CALLBACK (trampoline index)
          (inst mov #!-win32 rdi #!+win32 rcx (fixnumize index))
          ;; arg1 to ENTER-ALIEN-CALLBACK (pointer to argument vector)
          (inst mov #!-win32 rsi #!+win32 rdx rsp)
          ;; add room on stack for return value
          (inst sub rsp (if (evenp arg-count)
                            (* n-word-bytes 2)
                            n-word-bytes))
          ;; arg2 to ENTER-ALIEN-CALLBACK (pointer to return value)
          (inst mov #!-win32 rdx #!+win32 r8 rsp)
          ;; Make new frame
          (inst push rbp)
          (inst mov  rbp rsp)
          #!+win32 (inst sub rsp #x20)
          #!+win32 (inst and rsp #x-20)
          ;; Call
          (inst mov rax (foreign-symbol-address "callback_wrapper_trampoline"))
          (inst call rax)
          ;; Back! Restore frame
          (inst mov rsp rbp)
          (inst pop rbp))

        ;; Result now on top of stack, put it in the right register
        (cond
          ((or (alien-integer-type-p result-type)
               (alien-pointer-type-p result-type)
               (alien-type-= #.(parse-alien-type 'system-area-pointer nil)
                             result-type))
           (inst mov rax [rsp]))
          ((or (alien-single-float-type-p result-type)
               (alien-double-float-type-p result-type))
           (inst movq xmm0 [rsp]))
          ((alien-void-type-p result-type))
          (t
           (error "Unrecognized alien type: ~A" result-type)))

        ;; Pop the arguments and the return value from the stack to get
        ;; the return address at top of stack.

        (inst add rsp (* (+ arg-count
                            ;; Plus the return value and make sure it's aligned
                            (if (evenp arg-count)
                                2
                                1))
                         n-word-bytes))
        ;; Return
        (inst ret))
      (finalize-segment segment)
      ;; Now that the segment is done, convert it to a static
      ;; vector we can point foreign code to.
      (let ((buffer (sb!assem::segment-buffer segment)))
        (make-static-vector (length buffer)
                            :element-type '(unsigned-byte 8)
                            :initial-contents buffer)))))
