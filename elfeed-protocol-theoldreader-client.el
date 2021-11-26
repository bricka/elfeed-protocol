;;; elfeed-protocol-theoldreader-client.el --- client for making requests against TheOldReader API -*- lexical-binding: t; -*-

;;; Commentary:

;; This is code used to make API requests to TheOldReader.
;;
;; All requests are parsed via `json-read' and return the parsed data.

;;; Code:

(require 'deferred)
(require 'request-deferred)

(defun elfeed-theoldreader--client-qualify-item-id (id)
  "Qualify the given raw item ID."
  (concat "tag:google.com,2005:reader/item/" id)
  )

(defun elfeed-theoldreader--client-make-request (method url expect-output token params body)
  "Make a METHOD request to URL with TOKEN.  If EXPECT-OUTPUT, parse as JSON.

PARAMS will be sent in query.  BODY will be sent as key=value in body."
  (deferred:$
    (request-deferred
     url
     :type method
     :params (if expect-output
                 (cons '(output . json) params)
               params)
     :data body
     :headers `(("Authorization" . ,(format "GoogleLogin auth=%s" token))
                ("User-Agent" . ,elfeed-user-agent))
     :parser (if expect-output
                 (lambda ()
                   (let ((json-array-type 'list))
                     (json-read)))
               (lambda () nil))
     )
    (deferred:nextc it
      (lambda (response) (request-response-data response))
      )
    )
  )

(defun elfeed-theoldreader--client-get-folders (token)
  "Get all folders for the user using TOKEN."
  (elfeed-theoldreader--client-make-request "GET" "https://theoldreader.com/reader/api/0/tag/list" t token nil nil)
  )

(defun elfeed-theoldreader--client-get-all-subscriptions (token)
  "Get all subscriptions for the user using TOKEN.  The return value has one top-level field: 'subscriptions."
  (elfeed-theoldreader--client-make-request "GET" "https://theoldreader.com/reader/api/0/subscription/list" t token nil nil)
  )

(defun elfeed-theoldreader--client-get-items-for-subscription (token subscription-id newer-than)
  "Get all items in SUBSCRIPTION-ID newer than NEWER-THAN (seconds from epoch) using TOKEN.  The return value has two top-level fields: 'itemRefs and 'continuation."
  (elfeed-theoldreader--client-make-request
   "GET"
   "https://theoldreader.com/reader/api/0/stream/items/ids"
   t
   token
   `((s . ,subscription-id)
     (r . o)
     (ot . ,newer-than))
   nil)
  )

(defun elfeed-theoldreader--client-get-item-contents (token item-ids)
  "Get item details for ITEM-IDS using TOKEN.  ITEM-IDS must already be qualified, such as by calling `elfeed-theoldreader-client-qualify-item-ids'."
  (if (and item-ids (listp item-ids))
      (elfeed-theoldreader--client-make-request
       "POST"
       "https://theoldreader.com/reader/api/0/stream/items/contents"
       t
       token
       nil
       (mapcar (lambda (x) (cons 'i x)) item-ids))
    (signal 'wrong-type-argument "item-ids must be non-empty list"))
  )

(defun elfeed-theoldreader--client-get-items (token newer-than)
  "Get all items newer than NEWER-THAN (seconds from epoch) using TOKEN.  The return value has two top-level fields: 'itemRefs and 'continuation."
  (elfeed-theoldreader--client-make-request
   "GET"
   "https://theoldreader.com/reader/api/0/stream/items/ids"
   t
   token
   `((s . "user/-/state/com.google/reading-list")
     (r . o)
     (n . 1000)
     (ot . ,newer-than)
     )
   nil)
  )

(defun elfeed-theoldreader--client-get-latest-items (token)
  "Get the latest item using TOKEN.  The return value has two top-level fields: 'itemRefs and 'continuation."
  (elfeed-theoldreader--client-make-request
   "GET"
   "https://theoldreader.com/reader/api/0/stream/items/ids"
   t
   token
   `((s . "user/-/state/com.google/reading-list")
     (n . 1000)
     )
   nil)
  )

(defun elfeed-theoldreader--client-edit-tag (token ids tag)
  "Edit the IDS by applying TAG, using TOKEN for authentication.

TAG should be in the format ([ar] . TAG-STRING)."
  (elfeed-theoldreader--client-make-request
   "POST"
   "https://theoldreader.com/reader/api/0/edit-tag"
   nil
   token
   nil
   (cons tag (mapcar (lambda (id) `(i . ,id)) ids))
   )
  )

(defun elfeed-theoldreader--client-mark-ids-read (token ids)
  "Mark the given IDS as read, using TOKEN for authentication."
  (elfeed-theoldreader--client-edit-tag token ids '(a . "user/-/state/com.google/read"))
  )

(defun elfeed-theoldreader--client-mark-ids-unread (token ids)
  "Mark the given IDS as unread, using TOKEN for authentication."
  (elfeed-theoldreader--client-edit-tag token ids '(r . "user/-/state/com.google/read"))
  )

(defun elfeed-theoldreader--client-mark-ids-starred (token ids)
  "Mark the given IDS as starred, using TOKEN for authentication."
  (elfeed-theoldreader--client-edit-tag token ids '(a . "user/-/state/com.google/starred"))
  )

(defun elfeed-theoldreader--client-mark-ids-unstarred (token ids)
  "Mark the given IDS as unstarred, using TOKEN for authentication."
  (elfeed-theoldreader--client-edit-tag token ids '(r . "user/-/state/com.google/starred"))
  )

(provide 'elfeed-protocol-theoldreader-client)

;;; elfeed-protocol-theoldreader-client.el ends here
