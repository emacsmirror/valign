;;; valign.el --- Visually align tables      -*- lexical-binding: t; -*-

;; Author: Yuan Fu <casouri@gmail.com>
;; URL: https://github.com/casouri/valign
;; Version: 2.3.0
;; Keywords: convenience
;; Package-Requires: ((emacs "26.0"))

;;; This file is NOT part of GNU Emacs

;;; Commentary:
;;
;; This package provides visual alignment for Org Mode, Markdown and
;; table.el tables on GUI Emacs.  It can properly align tables
;; containing variable-pitch font, CJK characters and images.  In the
;; meantime, the text-based alignment generated by Org mode (or
;; Markdown mode) is left untouched.
;;
;; To use this package, add `valign-mode' to `org-mode-hook'.  If you
;; want to align a table manually, run M-x valign-table RET on a
;; table.
;;
;; TODO:
;;
;; - Hidden links in markdown still occupy the full length of the link
;;   because it uses character composition, which we don’t support.

;;; Developer:
;;
;; We decide to re-align in jit-lock hook, that means any change that
;; causes refontification will trigger re-align.  This may seem
;; inefficient and unnecessary, but there are just too many things
;; that can mess up a table’s alignment.  Therefore it is the most
;; reliable to re-align every time there is a refontification.
;; However, we do have a small optimization for typing in a table: if
;; the last command is 'self-insert-command', we don’t realign.  That
;; should improve the typing experience in large tables.

;;; Code:
;;

(require 'cl-generic)
(require 'cl-lib)
(require 'pcase)

(defcustom valign-lighter " valign"
  "The lighter string used by function `valign-mode'."
  :group 'valign
  :type 'string)

;;; Backstage

(define-error 'valign-bad-cell "Valign encountered a invalid table cell")
(define-error 'valign-not-gui "Valign only works in GUI environment")
(define-error 'valign-not-on-table "Valign is asked to align a table, but the point is not on one")

;;;; Table.el tables

(defvar valign-box-charset-alist
  '((ascii . "
+-++
| ||
+-++
+-++")
    (unicode . "
┌─┬┐
│ ││
├─┼┤
└─┴┘"))
  "An alist of (NAME . CHARSET).
A charset tells ftable how to parse the table.  I.e., what are the
box drawing characters to use.  Don’t forget the first newline.
NAME is the mnemonic for that charset.")

(defun valign-box-char (code charset)
  "Return a specific box drawing character in CHARSET.

Return a string.  CHARSET should be like `ftable-box-char-set'.
Mapping between CODE and position:

    ┌┬┐     123
    ├┼┤ <-> 456
    └┴┘     789

    ┌─┐     1 H 3    H: horizontal
    │ │ <-> V   V    V: vertical
    └─┘     7 H 9

Examples:

    (ftable-box-char 'h charset) => \"─\"
    (ftable-box-char 2 charset)  => \"┬\""
  (let ((index (pcase code
                 ('h 10)
                 ('v 11)
                 ('n 12)
                 ('s 13)
                 (_ code))))

    (char-to-string
     (aref charset ;        1 2 3 4  5  6  7  8  9  H V N S
           (nth index '(nil 1 3 4 11 13 14 16 18 19 2 6 0 7))))))

;;;; Auxilary

(defun valign--cell-alignment ()
  "Return how is current cell aligned.
Return 'left if aligned left, 'right if aligned right.
Assumes point is after the left bar (“|”).
Doesn’t check if we are in a cell."
  (save-excursion
    (if (looking-at " [^ ]")
        'left
      (if (not (search-forward "|" nil t))
          (signal 'valign-bad-cell nil)
        (if (looking-back
             "[^ ] |" (max (- (point) 3) (point-min)))
            'right
          'left)))))

(defun valign--cell-content-config (&optional bar-char)
  "Return (CELL-BEG CONTENT-BEG CONTENT-END CELL-END).
CELL-BEG is after the left bar, CELL-END is before the right bar.
CELL-CONTENT contains the actual non-white-space content,
possibly with a single white space padding on the either side, if
there are more than one white space on that side.

If the cell is empty, CONTENT-BEG is

    (min (CELL-BEG + 1) CELL-END)

CONTENT-END is

    (max (CELL-END - 1) CELL-BEG)

BAR-CHAR is the separator character (“|”).  It is actually a
string. Defaults to the normal bar: “|”, but you can provide a
unicode one for unicode tables.

Assumes point is after the left bar (“|”).  Assumes there is a
right bar."
  (save-excursion
    (let* ((bar-char (or bar-char "|"))
           (cell-beg (point))
           (cell-end (save-excursion
                       (search-forward bar-char (line-end-position))
                       (match-beginning 0)))
           ;; `content-beg-strict' is the beginning of the content
           ;; excluding any white space. Same for `content-end-strict'.
           content-beg-strict content-end-strict)
      (if (save-excursion (skip-chars-forward " ")
                          (looking-at-p bar-char))
          ;; Empty cell.
          (list cell-beg
                (min (1+ cell-beg) cell-end)
                (max (1- cell-end) cell-beg)
                cell-end)
        ;; Non-empty cell.
        (skip-chars-forward " ")
        (setq content-beg-strict (point))
        (goto-char cell-end)
        (skip-chars-backward " ")
        (setq content-end-strict (point))
        ;; Calculate delimiters. Basically, we try to preserve a white
        ;; space on the either side of the content, i.e., include them
        ;; in (BEG . END). Because if you are typing in a cell and
        ;; type a space, you probably want valign to keep that space
        ;; as cell content, rather than to consider it as part of the
        ;; padding and add overlay over it.
        (list cell-beg
              (if (= (- content-beg-strict cell-beg) 1)
                  content-beg-strict
                (1- content-beg-strict))
              (if (= (- cell-end content-end-strict) 1)
                  content-end-strict
                (1+ content-end-strict))
              cell-end)))))

(defun valign--cell-empty-p ()
  "Return non-nil if cell is empty.
Assumes point is after the left bar (“|”)."
  (save-excursion
    (and (skip-chars-forward " ")
         (looking-at "|"))))

(defun valign--cell-content-width (&optional bar-char)
  "Return the pixel width of the cell at point.
Assumes point is after the left bar (“|”).  Return nil if not in
a cell.  BAR-CHAR is the bar character (“|”)."
  ;; We assumes:
  ;; 1. Point is after the left bar (“|”).
  ;; 2. Cell is delimited by either “|” or “+”.
  ;; 3. There is at least one space on either side of the content,
  ;;    unless the cell is empty.
  ;; IOW: CELL      := <DELIM>(<EMPTY>|<NON-EMPTY>)<DELIM>
  ;;      EMPTY     := <SPACE>+
  ;;      NON-EMPTY := <SPACE>+<NON-SPACE>+<SPACE>+
  ;;      DELIM     := | or +
  (pcase-let* ((`(,_a ,beg ,end ,_b)
                (valign--cell-content-config bar-char)))
    (valign--pixel-width-from-to beg end)))

;; Sometimes, because of Org's table alignment, empty cell is longer
;; than non-empty cell.  This usually happens with CJK text, because
;; CJK characters are shorter than 2x ASCII character but Org treats
;; CJK characters as 2 ASCII characters when aligning.  And if you
;; have 16 CJK char in one cell, Org uses 32 ASCII spaces for the
;; empty cell, which is longer than 16 CJK chars.  So better regard
;; empty cell as 0-width rather than measuring it's white spaces.
(defun valign--cell-nonempty-width (&optional bar-char)
  "Return the pixel width of the cell at point.
If the cell is empty, return 0.  Otherwise return cell content’s
width.  BAR-CHAR is the bar character (“|”)."
  (if (valign--cell-empty-p) 0
    (valign--cell-content-width bar-char)))

;; We used to use a custom functions that calculates the pixel text
;; width that doesn’t require a live window.  However that function
;; has some limitations, including not working right with face remapping.
;; With this function we can avoid some of them.  However we still can’t
;; get the true tab width, see comment in ‘valgn--tab-width’ for more.
(defun valign--pixel-width-from-to (from to &optional with-prefix)
  "Return the width of the glyphs from FROM (inclusive) to TO (exclusive).
The buffer has to be in a live window.  FROM has to be less than
TO and they should be on the same line.  Valign display
properties must be cleaned before using this.

If WITH-PREFIX is non-nil, don’t subtract the width of line
prefix."
  (let* ((window (get-buffer-window))
         ;; This computes the prefix width.  This trick doesn’t seem
         ;; work if the point is at the beginning of a line, so we use
         ;; TO instead of FROM.
         ;;
         ;; Why all this fuss: Org puts some display property on white
         ;; spaces in a cell: (space :relative-width 1).  And that
         ;; messes up the calculation of prefix: now it returns the
         ;; width of a space instead of 0 when there is no line
         ;; prefix.  So we move the test point around until it doesn’t
         ;; sit on a character with display properties.
         (line-prefix
          (let ((pos to))
            (while (get-char-property pos 'display)
              (cl-decf pos))
            (car (window-text-pixel-size window pos pos)))))
    (- (car (window-text-pixel-size window from to))
       (if with-prefix 0 line-prefix)
       (if (bound-and-true-p display-line-numbers-mode)
           (line-number-display-width 'pixel)
         0))))

(defun valign--separator-p ()
  "If the current cell is actually a separator.
Assume point is after the left bar (“|”)."
  (or (eq (char-after) ?:) ;; Markdown tables.
      (eq (char-after) ?-)))

(defun valign--alignment-from-seperator ()
  "Return the alignment of this column.
Assumes point is after the left bar (“|”) of a separator
cell.  We don’t distinguish between left and center aligned."
  (save-excursion
    (if (eq (char-after) ?:)
        'left
      (skip-chars-forward "-")
      (if (eq (char-after) ?:)
          'right
        'left))))

(defmacro valign--do-row (row-idx-sym limit &rest body)
  "Go to each row’s beginning and evaluate BODY.
At each row, stop at the beginning of the line.  Start from point
and stop at LIMIT.  ROW-IDX-SYM is bound to each row’s
index (0-based)."
  (declare (debug (sexp form &rest form))
           (indent 2))
  `(progn
     (setq ,row-idx-sym 0)
     (while (<= (point) ,limit)
       (beginning-of-line)
       ,@body
       (forward-line)
       (cl-incf ,row-idx-sym))))

(defmacro valign--do-column (column-idx-sym bar-char &rest body)
  "Go to each column in the row and evaluate BODY.
Start from point and stop at the end of the line.  Stop after the
cell bar (“|”) in each iteration.  BAR-CHAR is \"|\" for the most
case.  COLUMN-IDX-SYM is bound to the index of the
column (0-based)."
  (declare (debug (sexp &rest form))
           (indent 2))
  `(progn
     (setq ,column-idx-sym 0)
     (beginning-of-line)
     (while (search-forward ,bar-char (line-end-position) t)
       ;; Unless we are after the last bar.
       (unless (looking-at (format "[^%s]*\n" (regexp-quote ,bar-char)))
         ,@body)
       (cl-incf ,column-idx-sym))))

(defun valign--alist-to-list (alist)
  "Convert an ALIST ((0 . a) (1 . b) (2 . c)) to (a b c)."
  (let ((inc 0) return-list)
    (while (alist-get inc alist)
      (push (alist-get inc alist)
            return-list)
      (cl-incf inc))
    (reverse return-list)))

(defun valign--calculate-cell-width (limit &optional bar-char)
  "Return a list of column widths.
Each column width is the largest cell width of the column.  Start
from point, stop at LIMIT.  BAR-CHAR is the bar character (“|”),
defaults to \"|\"."
  (let ((bar-char (or bar-char "|"))
        row-idx column-idx column-width-alist)
    (ignore row-idx)
    (save-excursion
      (valign--do-row row-idx limit
        (valign--do-column column-idx bar-char
          ;; Point is after the left “|”.
          ;;
          ;; Calculate this column’s pixel width, record it if it
          ;; is the largest one for this column.
          (unless (valign--separator-p)
            (let ((oldmax (alist-get column-idx column-width-alist))
                  (cell-width (valign--cell-nonempty-width bar-char)))
              ;; Why “=”: if cell-width is 0 and the whole column is 0,
              ;; still record it.
              (if (>= cell-width (or oldmax 0))
                  (setf (alist-get column-idx column-width-alist)
                        cell-width)))))))
    ;; Turn alist into a list.
    (mapcar (lambda (width) (+ width 16))
            (valign--alist-to-list column-width-alist))))

(cl-defmethod valign--calculate-alignment ((type (eql markdown)) limit)
  "Return a list of alignments ('left or 'right) for each column.
TYPE must be 'markdown.  Start at point, stop at LIMIT."
  (ignore type)
  (let (row-idx column-idx column-alignment-alist)
    (ignore row-idx)
    (save-excursion
      (valign--do-row row-idx limit
        (when (valign--separator-p)
          (valign--do-column column-idx "|"
            (setf (alist-get column-idx column-alignment-alist)
                  (valign--alignment-from-seperator))))))
    (if (not column-alignment-alist)
        (save-excursion
          (valign--do-column column-idx "|"
            (push 'left column-alignment-alist))
          column-alignment-alist)
      (valign--alist-to-list column-alignment-alist))))

(cl-defmethod valign--calculate-alignment ((type (eql org)) limit)
  "Return a list of alignments ('left or 'right) for each column.
TYPE must be 'org.  Start at point, stop at LIMIT."
  ;; Why can’t infer the alignment on each cell by its space padding?
  ;; Because the widest cell of a column has one space on both side,
  ;; making it impossible to infer the alignment.
  (ignore type)
  (let (column-idx column-alignment-alist row-idx)
    (ignore row-idx)
    (save-excursion
      (valign--do-row row-idx limit
        (valign--do-column column-idx "|"
          (when (not (valign--separator-p))
            (setf (alist-get column-idx column-alignment-alist)
                  (cons (valign--cell-alignment)
                        (alist-get column-idx column-alignment-alist))))))
      ;; Now we have an alist
      ;; ((0 . (left left right left ...) (1 . (...))))
      ;; For each column, we take the majority.
      (cl-labels ((majority (list)
                            (let ((left-count (cl-count 'left list))
                                  (right-count (cl-count 'right list)))
                              (if (> left-count right-count)
                                  'left 'right))))
        (mapcar #'majority
                (valign--alist-to-list column-alignment-alist))))))

(defun valign--at-table-p ()
  "Return non-nil if point is in a table."
  (save-excursion
    (beginning-of-line)
    (let ((face (plist-get (text-properties-at (point)) 'face)))
      (and (progn (skip-chars-forward " \t")
                  (member (char-to-string (char-after))
                          (append
                           (cl-loop for elt in valign-box-charset-alist
                                    for charset = (cdr elt)
                                    collect (valign-box-char 1 charset)
                                    collect (valign-box-char 4 charset)
                                    collect (valign-box-char 7 charset))
                           '("|"))))
           ;; Don’t align tables in org blocks.
           (not (and (consp face)
                     (or (equal face '(org-block))
                         (equal (plist-get face :inherit)
                                '(org-block)))))))))

(defun valign--beginning-of-table ()
  "Go backward to the beginning of the table at point.
Assumes point is on a table."
  ;; This implementation allows non-table lines before a table, e.g.,
  ;; #+latex: xxx
  ;; |------+----|
  (beginning-of-line)
  (while (and (< (point-min) (point))
              (valign--at-table-p))
    (forward-line -1))
  (unless (valign--at-table-p)
    (forward-line 1)))

(defun valign--end-of-table ()
  "Go forward to the end of the table at point.
Assumes point is on a table."
  (end-of-line)
  (if (not (search-forward "\n\n" nil t))
      (goto-char (point-max))
    (skip-chars-backward "\n")))

(defun valign--put-overlay (beg end &rest props)
  "Put overlay between BEG and END.
PROPS contains properties and values."
  (let ((ov (make-overlay beg end nil t nil)))
    (overlay-put ov 'valign t)
    (overlay-put ov 'evaporate t)
    (while props
      (overlay-put ov (pop props) (pop props)))))

(defun valign--put-text-prop (beg end &rest props)
  "Put text property between BEG and END.
PROPS contains properties and values."
  (add-text-properties beg end props)
  (put-text-property beg end 'valign t))

(defsubst valign--space (xpos)
  "Return a display property that aligns to XPOS."
  `(space :align-to (,xpos)))

(defvar valign-fancy-bar)
(defun valign--maybe-render-bar (point)
  "Make the character at POINT a full height bar.
But only if `valign-fancy-bar' is non-nil."
  (when valign-fancy-bar
    (valign--render-bar point)))

(defun valign--fancy-bar-cursor-fn (window prev-pos action)
  "Run when point enters or left a fancy bar.
Because the bar is so thin, the cursor disappears in it.  We
expands the bar so the cursor is visible.  'cursor-intangible
doesn’t work because it prohibits you to put the cursor at BOL.

WINDOW is just window, PREV-POS is the previous point of cursor
before event, ACTION is either 'entered or 'left."
  (ignore window)
  (with-silent-modifications
    (let ((ov-list (overlays-at (pcase action
                                  ('entered (point))
                                  ('left prev-pos)))))
      (dolist (ov ov-list)
        (when (overlay-get ov 'valign-bar)
          (overlay-put
           ov 'display (pcase action
                         ('entered (if (eq cursor-type 'bar)
                                       '(space :width (3)) " "))
                         ('left '(space :width (1))))))))))

(defun valign--render-bar (point)
  "Make the character at POINT a full-height bar."
  (with-silent-modifications
    (put-text-property point (1+ point)
                       'cursor-sensor-functions
                       '(valign--fancy-bar-cursor-fn))
    (valign--put-overlay point (1+ point)
                         'face '(:inverse-video t)
                         'display '(space :width (1))
                         'valign-bar t)))

(defun valign--clean-text-property (beg end)
  "Clean up the display text property between BEG and END."
  (with-silent-modifications
    (put-text-property beg end 'cursor-sensor-functions nil))
  ;; Remove overlays.
  (let ((ov-list (overlays-in beg end)))
    (dolist (ov ov-list)
      (when (overlay-get ov 'valign)
        (delete-overlay ov))))
  ;; Remove text properties.
  (let ((p beg) tab-end last-p)
    (while (not (eq p last-p))
      (setq last-p p
            p (next-single-char-property-change p 'valign nil end))
      (when (plist-get (text-properties-at p) 'valign)
        ;; We are at the beginning of a tab, now find the end.
        (setq tab-end (next-single-char-property-change
                       p 'valign nil end))
        ;; Remove text property.
        (with-silent-modifications
          (put-text-property p tab-end 'display nil)
          (put-text-property p tab-end 'valign nil))))))

(defun valign--glyph-width-of (string point)
  "Return the pixel width of STRING with font at POINT.
STRING should have length 1."
  (aref (aref (font-get-glyphs (font-at point) 0 1 string) 0) 4))

(defun valign--separator-row-add-overlay (beg end right-pos)
  "Add overlay to a separator row’s “cell”.
Cell ranges from BEG to END, the pixel position RIGHT-POS marks
the position for the right bar (“|”).
Assumes point is on the right bar or plus sign."
  ;; Make “+” look like “|”
  (if valign-fancy-bar
      ;; Render the right bar.
      (valign--render-bar end)
    (when (eq (char-after end) ?+)
      (let ((ov (make-overlay end (1+ end))))
        (overlay-put ov 'display "|")
        (overlay-put ov 'valign t))))
  ;; Markdown row
  (when (eq (char-after beg) ?:)
    (setq beg (1+ beg)))
  (when (eq (char-before end) ?:)
    (setq end (1- end)
          right-pos (- right-pos
                       (valign--pixel-width-from-to (1- end) end))))
  ;; End of Markdown
  (valign--put-overlay beg end
                       'display (valign--space right-pos)
                       'face '(:strike-through t)))

(defun valign--align-separator-row (column-width-list)
  "Align the separator row in multi column style.
COLUMN-WIDTH-LIST is returned by `valign--calculate-cell-width'."
  (let ((bar-width (valign--glyph-width-of "|" (point)))
        (space-width (valign--glyph-width-of " " (point)))
        (column-start (point))
        (col-idx 0)
        (pos (valign--pixel-width-from-to
              (line-beginning-position) (point) t)))
    ;; Render the first left bar.
    (valign--maybe-render-bar (1- (point)))
    ;; Add overlay in each column.
    (while (re-search-forward "[|\\+]" (line-end-position) t)
      ;; Render the right bar.
      (valign--maybe-render-bar (1- (point)))
      (let ((column-width (nth col-idx column-width-list)))
        (valign--separator-row-add-overlay
         column-start (1- (point)) (+ pos column-width space-width))
        (setq column-start (point)
              pos (+ pos column-width bar-width space-width))
        (cl-incf col-idx)))))

(defun valign--guess-table-type ()
  "Return either 'org or 'markdown."
  (cond ((derived-mode-p 'org-mode 'org-agenda-mode) 'org)
        ((derived-mode-p 'markdown-mode) 'markdown)
        ((string-match-p "org" (symbol-name major-mode)) 'org)
        ((string-match-p "markdown" (symbol-name major-mode)) 'markdown)
        (t 'org)))


;;; Userland

(defcustom valign-fancy-bar nil
  "Non-nil means to render bar as a full-height line.
You need to restart valign mode for this setting to take effect."
  :type '(choice
          (const :tag "Enable fancy bar" t)
          (const :tag "Disable fancy bar" nil))
  :group 'valign)

(defun valign-table ()
  "Visually align the table at point."
  (interactive)
  (valign-table-maybe t))

(defvar valign-not-align-after-list '(self-insert-command
                                      org-self-insert-command
                                      markdown-outdent-or-delete
                                      org-delete-backward-char
                                      backward-kill-word
                                      delete-char
                                      kill-word)
  "Valign doesn’t align table after these commands.")

(defun valign-table-maybe (&optional force)
  "Visually align the table at point.
If FORCE non-nil, force align."
  (condition-case err
      (save-excursion
        (when (and (display-graphic-p)
                   (valign--at-table-p)
                   (or force
                       (not (memq (or this-command last-command)
                                  valign-not-align-after-list))))
          (valign--beginning-of-table)
          (if (valign--guess-charset)
              (valign--table-2)
            (valign-table-1))))
    ((valign-bad-cell search-failed error)
     (valign--clean-text-property
      (save-excursion (valign--beginning-of-table) (point))
      (save-excursion (valign--end-of-table) (point)))
     (when (eq (car err) 'error)
       (error (error-message-string err))))))

(defun valign-table-1 ()
  "Visually align the table at point."
  (valign--beginning-of-table)
  (let* ((space-width (valign--glyph-width-of " " (point)))
         (bar-width (valign--glyph-width-of "|" (point)))
         (table-beg (point))
         (table-end (save-excursion (valign--end-of-table) (point)))
         ;; Very hacky, but..
         (_ (valign--clean-text-property table-beg table-end))
         (column-width-list (valign--calculate-cell-width table-end))
         (column-alignment-list (valign--calculate-alignment
                                 (valign--guess-table-type) table-end))
         row-idx column-idx column-start)
    (ignore row-idx)

    ;; Align each row.
    (valign--do-row row-idx table-end
      (re-search-forward "|" (line-end-position))
      (if (valign--separator-p)
          ;; Separator row.
          (valign--align-separator-row column-width-list)

        ;; Not separator row, align each cell. ‘column-start’ is the
        ;; pixel position of the current point, i.e., after the left
        ;; bar.
        (setq column-start (valign--pixel-width-from-to
                            (line-beginning-position) (point) t))

        (valign--do-column column-idx "|"
          (save-excursion
            ;; We are after the left bar (“|”).
            ;; Render the left bar.
            (valign--maybe-render-bar (1- (point)))
            ;; Start aligning this cell.
            ;;      Pixel width of the column.
            (let* ((col-width (nth column-idx column-width-list))
                   ;; left or right aligned.
                   (alignment (nth column-idx column-alignment-list))
                   ;; Pixel width of the cell.
                   (cell-width (valign--cell-content-width)))
              ;; Align cell.
              (cl-labels ((valign--put-ov
                           (beg end xpos)
                           (valign--put-overlay beg end 'display
                                                (valign--space xpos))))
                (pcase-let ((`(,cell-beg
                               ,content-beg
                               ,content-end
                               ,cell-end)
                             (valign--cell-content-config)))
                  (cond ((= cell-beg content-beg)
                         ;; This cell has only one space.
                         (valign--put-ov
                          cell-beg cell-end
                          (+ column-start col-width space-width)))
                        ;; Empty cell.  Sometimes empty cells are
                        ;; longer than other non-empty cells (see
                        ;; `valign--cell-width'), so we put overlay on
                        ;; all but the first white space.
                        ((valign--cell-empty-p)
                         (valign--put-ov
                          content-beg cell-end
                          (+ column-start col-width space-width)))
                        ;; A normal cell.
                        (t
                         (pcase alignment
                           ;; Align a left-aligned cell.
                           ('left (valign--put-ov
                                   content-end cell-end
                                   (+ column-start
                                      col-width space-width)))
                           ;; Align a right-aligned cell.
                           ('right (valign--put-ov
                                    cell-beg content-beg
                                    (+ column-start
                                       (- col-width cell-width)))))))))
              ;; Update ‘column-start’ for the next cell.
              (setq column-start (+ column-start
                                    col-width
                                    bar-width
                                    space-width)))))
        ;; Now we are at the last right bar.
        (valign--maybe-render-bar (1- (point)))))))

(defun valign--table-2 ()
  "Visually align the table.el table at point."
  ;; Instead of overlays, we use text properties in this function.
  ;; Too many overlays degrades performance, and we add a whole bunch
  ;; of them in this function, so better use text properties.
  (valign--beginning-of-table)
  (let* ((charset (valign--guess-charset))
         (ucharset (alist-get 'unicode valign-box-charset-alist))
         (char-width (with-silent-modifications
                       (insert (valign-box-char 1 ucharset))
                       (prog1 (valign--pixel-width-from-to
                               (1- (point)) (point))
                         (backward-delete-char 1))))
         (table-beg (point))
         (table-end (save-excursion (valign--end-of-table) (point)))
         ;; Very hacky, but..
         (_ (valign--clean-text-property table-beg table-end))
         (column-width-list
          ;; Make every width multiples of CHAR-WIDTH.
          (mapcar (lambda (x)
                    (* char-width (1+ (/ (- x 16) char-width))))
                  (valign--calculate-cell-width
                   table-end (valign-box-char 'v charset))))
         (row-idx 0)
         (column-idx 0)
         (column-start 0))
    (while (< (point) table-end)
      (save-excursion
        (skip-chars-forward " \t")
        (if (not (equal (char-to-string (char-after))
                        (valign-box-char 'v charset)))
            ;; Render separator line.
            (valign--align-separator-row-full
             column-width-list
             (cond ((valign--first-line-p table-beg table-end)
                    '(1 2 3))
                   ((valign--last-line-p table-beg table-end)
                    '(7 8 9))
                   (t '(4 5 6)))
             charset char-width)
          ;; Render normal line.
          (setq column-start (valign--pixel-width-from-to
                              (line-beginning-position) (point) t)
                column-idx 0)
          (while (search-forward (valign-box-char 'v charset)
                                 (line-end-position) t)
            (valign--put-text-prop
             (1- (point)) (point)
             'display (valign-box-char 'v ucharset))
            (unless (looking-at "\n")
              (pcase-let ((col-width (nth column-idx column-width-list))
                          (`(,cell-beg ,content-beg
                                       ,content-end ,cell-end)
                           (valign--cell-content-config
                            (valign-box-char 'v charset))))
                (valign--put-text-prop
                 content-end cell-end 'display
                 (valign--space (+ column-start col-width char-width)))
                (cl-incf column-idx)
                (setq column-start
                      (+ column-start col-width char-width)))))))
      (cl-incf row-idx)
      (forward-line))))

(defun valign--first-line-p (beg end)
  "Return t if the point is in the first line between BEG and END."
  (ignore end)
  (save-excursion
    (not (search-backward "\n" beg t))))

(defun valign--last-line-p (beg end)
  "Return t if the point is in the last line between BEG and END."
  (ignore beg)
  (save-excursion
    (not (search-forward "\n" end t))))

(defun valign--align-separator-row-full
    (column-width-list codeset charset char-width)
  "Align separator row for a full table (table.el table).

COLUMN-WIDTH-LIST is a list of column widths.  CODESET is a list
of codes that corresponds to the left, middle and right box
drawing character codes to pass to `valign-box-char'.  It can
be (1 2 3), (4 5 6), or (7 8 9).  CHARSET is the same as in
`valign-box-charset-alist'.  CHAR-WIDTH is the pixel width of a
character.

Assumes point before the first character."
  (let* ((middle (valign-box-char (nth 1 codeset) charset))
         (right (valign-box-char (nth 2 codeset) charset))
         ;; UNICODE-CHARSET is used for overlay, CHARSET is used for
         ;; the physical table.
         (unicode-charset (alist-get 'unicode valign-box-charset-alist))
         (uleft (valign-box-char (nth 0 codeset) unicode-charset))
         (umiddle (valign-box-char (nth 1 codeset) unicode-charset))
         (uright (valign-box-char (nth 2 codeset) unicode-charset))
         ;; Aka unicode horizontal.
         (uh (valign-box-char 'h unicode-charset))
         (eol (line-end-position))
         (col-idx 0))
    (valign--put-text-prop (point) (1+ (point)) 'display uleft)
    (goto-char (1+ (point)))
    (while (re-search-forward (rx-to-string `(or ,middle ,right)) eol t)
      ;; Render joints.
      (if (looking-at "\n")
          (valign--put-text-prop (1- (point)) (point) 'display uright)
        (valign--put-text-prop (1- (point)) (point) 'display umiddle))
      ;; Render horizontal lines.
      (save-excursion
        (let ((p (1- (point)))
              (width (nth col-idx column-width-list)))
          (goto-char p)
          (skip-chars-backward (valign-box-char 'h charset))
          (valign--put-text-prop (point) p 'display
                                 (make-string (/ width char-width)
                                              (aref uh 0)))))
      (cl-incf col-idx))))

(defun valign--guess-charset ()
  "Return the charset used by the table at point.
Assumes point at the beginning of the table."
  (cl-loop for charset
           in (mapcar #'cdr valign-box-charset-alist)
           if (equal (char-to-string (char-after))
                     (valign-box-char 1 charset))
           return charset
           finally return nil))

;;; Mode intergration

(defun valign-region (&optional beg end)
  "Align tables between BEG and END.
Supposed to be called from jit-lock.
Force align if FORCE non-nil."
  ;; Text sized can differ between frames, only use current frame.
  ;; We only align when this buffer is in a live window, because we
  ;; need ‘window-text-pixel-size’ to calculate text size.
  (let* ((beg (or beg (point-min)))
         (end (or end (point-max)))
         (fontified-end end))
    (when (window-live-p (get-buffer-window nil (selected-frame)))
      (save-excursion
        (goto-char beg)
        (while (and (search-forward "|" nil t)
                    (< (point) end))
          (condition-case err
              (valign-table-maybe)
            (error (message "Error when aligning table: %s"
                            (error-message-string err))))
          (valign--end-of-table)
          (setq fontified-end (point)))))
    (cons 'jit-lock-bounds (cons beg (max end fontified-end)))))

(defvar valign-mode)
(defun valign--buffer-advice (&rest _)
  "Realign whole buffer."
  (when valign-mode
    (valign-region)))

(defvar org-indent-agentized-buffers)
(defun valign--org-indent-advice (&rest _)
  "Re-align after org-indent is done."
  ;; See ‘org-indent-initialize-agent’.
  (when (not org-indent-agentized-buffers)
    (valign--buffer-advice)))

;; When an org link is in an outline fold, it’s full length
;; is used, when the subtree is unveiled, org link only shows
;; part of it’s text, so we need to re-align.  This function
;; runs after the region is flagged. When the text
;; is shown, jit-lock will make valign realign the text.
(defun valign--flag-region-advice (beg end flag &optional _)
  "Valign hook, realign table between BEG and END.
FLAG is the same as in ‘org-flag-region’."
  (when (and valign-mode (not flag))
    (with-silent-modifications
      (put-text-property beg end 'fontified nil))))

(defun valign--tab-advice (&rest _)
  "Force realign after tab so user can force realign."
  (when (and valign-mode
             (valign--at-table-p))
    (valign-table)))

(defun valign-reset-buffer ()
  "Remove alignment in the buffer."
  (with-silent-modifications
    (valign--clean-text-property (point-min) (point-max))
    (jit-lock-refontify)))

(defun valign-remove-advice ()
  "Remove advices added by valign."
  (interactive)
  (dolist (fn '(org-cycle
                org-table-blank-field
                markdown-cycle))
    (advice-remove fn #'valign--tab-advice))
  (dolist (fn '(text-scale-increase
                text-scale-decrease
                org-agenda-finalize-hook))
    (advice-remove fn #'valign--buffer-advice))
  (dolist (fn '(org-flag-region outline-flag-region))
    (advice-remove fn #'valign--flag-region-advice)))

;;; Userland

;;;###autoload
(define-minor-mode valign-mode
  "Visually align Org tables."
  :require 'valign
  :group 'valign
  :lighter valign-lighter
  (if (not (display-graphic-p))
      (when valign-mode
        (message "Valign mode has no effect in non-graphical display"))
    (if valign-mode
        (progn
          (add-hook 'jit-lock-functions #'valign-region 98 t)
          (dolist (fn '(org-cycle
                        ;; Why this function?  If you tab into an org
                        ;; field (cell) and start typing right away,
                        ;; org clears that field for you with this
                        ;; function.  The problem is, this functions
                        ;; messes up the overlay and makes the bar
                        ;; invisible.  So we have to fix the overlay
                        ;; after this function.
                        org-table-blank-field
                        markdown-cycle))
            (advice-add fn :after #'valign--tab-advice))
          (dolist (fn '(text-scale-increase
                        text-scale-decrease
                        org-agenda-finalize-hook
                        org-toggle-inline-images))
            (advice-add fn :after #'valign--buffer-advice))
          (dolist (fn '(org-flag-region outline-flag-region))
            (advice-add fn :after #'valign--flag-region-advice))
          (with-eval-after-load 'org-indent
            (advice-add 'org-indent-initialize-agent
                        :after #'valign--org-indent-advice))
          (add-hook 'org-indent-mode-hook #'valign--buffer-advice 0 t)
          (if valign-fancy-bar (cursor-sensor-mode))
          (jit-lock-refontify))
      (with-eval-after-load 'org-indent
        (advice-remove 'org-indent-initialize-agent
                       #'valign--org-indent-advice))
      (remove-hook 'jit-lock-functions #'valign-region t)
      (valign-reset-buffer)
      (cursor-sensor-mode -1))))

(provide 'valign)

;;; valign.el ends here

;; Local Variables:
;; sentence-end-double-space: t
;; End:
