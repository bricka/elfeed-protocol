;;; elfeed-protocol-theoldreader.el --- TheOldReader protocol for elfeed -*- lexical-binding: t; -*-

;; Author: Alex Figl-Brick <alex@alexbrick.me>

;;; Commentary:

;;; Code:

(require 'deferred)
(require 'elfeed-protocol-theoldreader-client)
(require 'elfeed-protocol)

(defconst elfeed-protocol-theoldreader--feed-id-to-url
  (make-hash-table
   :test 'equal
   )
  "A map of feed IDs as returned by the API to the feed URL."
  )

(defconst elfeed-protocol-theoldreader--api-read-tag
  "user/-/state/com.google/read"
  "The tag in the API that indicates an entry is read."
  )

(defvar elfeed-protocol-theoldreader-star-tag 'star
  "Tag that indicates content is starred.")

(defun elfeed-protocol-theoldreader--proto-id (host-url)
  "Get TheOldReader protocol ID for given HOST-URL."
  (elfeed-protocol-id "theoldreader" host-url)
  )

(defun elfeed-protocol-theoldreader--set-update-mark (proto-id mark)
  (elfeed-log 'debug "elfeed-theoldreader: Setting update mark for proto %s to %s" proto-id mark)
  "Set last update mark to elfeed db. PROTO-ID is the target protocol feed id.  MARK is the value."
  (elfeed-protocol-set-feed-meta-data proto-id :last-crawl-time mark))

(defun elfeed-protocol-theoldreader--get-update-mark (proto-id)
  (or (elfeed-protocol-get-feed-meta-data proto-id :last-crawl-time) -1))

(defun elfeed-protocol-theoldreader--split-and-call-in-parallel (token func things)
  "Split THINGS into groups of 100 and call FUNC in parallel for each group, using TOKEN for authentication.

FUNC must accept two arguments: (TOKEN LIST)."
  (deferred:parallel
    (mapcar
     (lambda (sub-things)
       (funcall func token sub-things)
       )
     (seq-partition things 100))
    )
  )

(defun elfeed-protocol-theoldreader--sync-pending-ids (host-url)
  "Sync pending read/unread/starred/unstarred entry states to HOST-URL."
  (let* ((proto-id (elfeed-protocol-theoldreader--proto-id host-url))
         (token (elfeed-protocol-meta-password proto-id))
         (pending-read-ids (elfeed-protocol-get-pending-ids proto-id :pending-read))
         (pending-unread-ids (elfeed-protocol-get-pending-ids proto-id :pending-unread))
         (pending-starred-ids (elfeed-protocol-get-pending-ids proto-id :pending-starred))
         (pending-unstarred-ids (elfeed-protocol-get-pending-ids proto-id :pending-unstarred)))
    (deferred:$
      (deferred:parallel
        (list
         (elfeed-protocol-theoldreader--split-and-call-in-parallel token 'elfeed-theoldreader--client-mark-ids-read pending-read-ids)
         (elfeed-protocol-theoldreader--split-and-call-in-parallel token 'elfeed-theoldreader--client-mark-ids-unread pending-unread-ids)
         (elfeed-protocol-theoldreader--split-and-call-in-parallel token 'elfeed-theoldreader--client-mark-ids-starred pending-starred-ids)
         (elfeed-protocol-theoldreader--split-and-call-in-parallel token 'elfeed-theoldreader--client-mark-ids-unstarred pending-unstarred-ids)
         )
        )
      (deferred:nextc it
        (lambda (&rest _)
          (elfeed-protocol-clean-pending-ids proto-id)
          )
        )
      (deferred:error it
        (lambda (e)
          (elfeed-log 'warn "elfeed-protocol-theoldreader: failed to sync pending IDs due to: %s" e)
          )
        )
      )
    )
  )

(defun elfeed-protocol-theoldreader--map-json-to-entry (host-url item-content-json)
  (let ((proto-id (elfeed-protocol-theoldreader--proto-id host-url)))
    (let-alist item-content-json
      (elfeed-entry--create
       :id .id
       :title (elfeed-cleanup .title)
       :link (elfeed-cleanup (alist-get 'href (car .canonical)))
       :date (elfeed-new-date-for-entry nil .updated)
       :content .summary.content
       :content-type 'html
       :tags (if (member elfeed-protocol-theoldreader--api-read-tag .categories)
                 (remove 'unread elfeed-initial-tags)
               elfeed-initial-tags
               )
       :feed-id (elfeed-protocol-format-subfeed-id
                 proto-id
                 (gethash .origin.streamId elfeed-protocol-theoldreader--feed-id-to-url elfeed-protocol-unknown-feed-url))
       :meta (list
              :protocol-id proto-id
              :id .id
              )
       )
      )
    ))

(defun elfeed-protocol-theoldreader--set-feed-data (host-url api-feed-id feed-url feed-title)
  "Set the correct data for a feed in the database.

API-FEED-ID is the feed ID from the API (format feed/UUID).  FEED-URL is the URL of the feed.  FEED-TITLE is the name of the feed."
  (let* ((feed-id (elfeed-protocol-format-subfeed-id (elfeed-protocol-theoldreader--proto-id host-url) feed-url))
         (feed-db (elfeed-db-get-feed feed-id)))
    (setf (elfeed-feed-url feed-db) feed-id)
    (setf (elfeed-feed-title feed-db) feed-title)
    (puthash api-feed-id feed-url elfeed-protocol-theoldreader--feed-id-to-url)
    )
  )

(defun elfeed-protocol-theoldreader--seed-feed-db (host-url token)
  (deferred:$
    (elfeed-theoldreader--client-get-all-subscriptions token)
    (deferred:nextc it
      (lambda (data)
        (clrhash elfeed-protocol-theoldreader--feed-id-to-url)
        (let-alist data
          (dolist (subscription .subscriptions)
            (let-alist subscription
              (elfeed-protocol-theoldreader--set-feed-data host-url .id .url .title))
            .subscriptions)
          )
        ))
    )
  )

(defun elfeed-protocol-theoldreader--do-update (host-url action start callback)
  "Fetch entries for HOST-URL and update database.
If CALLBACK is provided, also call it with the entries.

ACTION can be either 'init or 'update.

If ACTION is 'init, START is ignored, and the most recent entries are fetched.

If ACTION is 'update, we fetch the next entries starting at START."
  (let* ((proto-id (elfeed-protocol-theoldreader--proto-id host-url))
         (token (elfeed-protocol-meta-password proto-id)))
    (when (eq action 'init)
      (elfeed-protocol-theoldreader--set-update-mark proto-id -1)
      (elfeed-protocol-clean-pending-ids proto-id)
      (elfeed-protocol-add-unknown-feed proto-id)
      )
    (deferred:$
      (elfeed-protocol-theoldreader--seed-feed-db host-url token)
      (deferred:nextc it
        (lambda (_)
          (if (eq action 'init)
              (elfeed-theoldreader--client-get-latest-items token)
            (elfeed-theoldreader--client-get-items token start)
            )
          )
        )
      (deferred:nextc it
        (lambda (data)
          (let-alist data
            (when .itemRefs
              (let ((item-ids
                     (mapcar (lambda (x) (elfeed-theoldreader--client-qualify-item-id (alist-get 'id x))) .itemRefs)))
                (elfeed-theoldreader--client-get-item-contents token item-ids)
                ))
            )))
      (deferred:nextc it
        (lambda (content-data)
          (if content-data
              (let-alist content-data
                (let ((entries (mapcar (lambda (item-json) (elfeed-protocol-theoldreader--map-json-to-entry host-url item-json)) .items))
                      (latest-item (if (eq action 'init) (car .items) (car (last .items)))))
                  (elfeed-db-add entries)
                  (when callback
                    (funcall callback entries))
                  ;; Now determine the crawl time that we need to start with on the next pass
                  (let-alist latest-item
                    (elfeed-log 'debug "elfeed-protocol-theoldreader: latest item has ID %s" .id)
                    (let* ((crawl-time-s (floor (/ (string-to-number .crawlTimeMsec) 1000))))
                      (elfeed-protocol-theoldreader--set-update-mark proto-id crawl-time-s)
                      )
                    )
                  )
                )
            (when callback
              (funcall callback nil))
            )))
      (deferred:error it
        (lambda (e)
          (elfeed-log 'error "elfeed-protocol-theoldreader: failed to update entries due to: %s" e)))
      )
    )
  )

(defun elfeed-protocol-theoldreader-update (host-or-subfeed-url &optional callback)
  (interactive)
  (let* ((host-url (elfeed-protocol-host-url host-or-subfeed-url))
         (proto-id (elfeed-protocol-theoldreader--proto-id host-url))
         (last-crawl-timestamp (elfeed-protocol-theoldreader--get-update-mark proto-id)))
    (deferred:$
      (elfeed-protocol-theoldreader--sync-pending-ids host-url)
      (deferred:nextc it
        (lambda (_)
          (if (and last-crawl-timestamp (> last-crawl-timestamp 0))
              (elfeed-protocol-theoldreader--do-update host-url 'update (1+ last-crawl-timestamp) callback)
            (elfeed-protocol-theoldreader--do-update host-url 'init nil callback)
            )
          ))
      )
    ))

(defun elfeed-protocol-theoldreader-entry-p (host-url entry)
  "Check if specific ENTRY is from TheOldReader."
  (string= (elfeed-protocol-entry-protocol-id entry) (elfeed-protocol-theoldreader--proto-id host-url))
  )

(defun elfeed-protocol-theoldreader--append-pending-id (host-url entry tag action)
  "Append read/unread/starred/unstarred ids to pending list.
ENTRY is the target entry object.
TAG is the action tag, for example 'unread and `elfeed-protocol-theoldreader-star-tag',
ACTION could be add or remove."
  (when (elfeed-protocol-theoldreader-entry-p host-url entry)
    (let* ((proto-id (elfeed-protocol-theoldreader--proto-id host-url))
           (id (elfeed-meta entry :id)))
      (cond
       ((eq action 'add)
        (cond
         ((eq tag 'unread)
          (elfeed-protocol-append-pending-ids proto-id :pending-unread (list id))
          (elfeed-protocol-remove-pending-ids proto-id :pending-read (list id)))
         ((eq tag elfeed-protocol-theoldreader-star-tag)
          (elfeed-protocol-append-pending-ids proto-id :pending-starred (list id))
          (elfeed-protocol-remove-pending-ids proto-id :pending-unstarred (list id)))))
       ((eq action 'remove)
        (cond
         ((eq tag 'unread)
          (elfeed-protocol-append-pending-ids proto-id :pending-read (list id))
          (elfeed-protocol-remove-pending-ids proto-id :pending-unread (list id)))
         ((eq tag elfeed-protocol-theoldreader-star-tag)
          (elfeed-protocol-append-pending-ids proto-id :pending-unstarred (list id))
          (elfeed-protocol-remove-pending-ids proto-id :pending-starred (list id)))))))))

(defun elfeed-protocol-theoldreader-pre-tag (host-url entries &rest tags)
  "Sync unread and starred states before tags added.
ENTRIES is the target entry objects.  TAGS is the tags are adding now."
  (dolist (tag tags)
    (cl-loop for entry in entries
             unless (elfeed-tagged-p tag entry)
             do (elfeed-protocol-theoldreader--append-pending-id host-url entry tag 'add)))
  (unless elfeed-protocol-lazy-sync
    (elfeed-protocol-theoldreader--sync-pending-ids host-url)))

(defun elfeed-protocol-theoldreader-pre-untag (host-url entries &rest tags)
  "Sync unread and starred states before tags removed.
ENTRIES is the target entry objects.  TAGS is the tags are adding now."
  (dolist (tag tags)
    (cl-loop for entry in entries
             when (elfeed-tagged-p tag entry)
             do (elfeed-protocol-theoldreader--append-pending-id host-url entry tag 'remove)))
  (unless elfeed-protocol-lazy-sync
    (elfeed-protocol-theoldreader--sync-pending-ids host-url)))

(defun elfeed-protocol-theoldreader-register-protocol ()
  "Register the \"theoldreader\" elfeed protocol handler."
  (elfeed-protocol-register "theoldreader"
                            (list :update 'elfeed-protocol-theoldreader-update
                                  :pre-tag 'elfeed-protocol-theoldreader-pre-tag
                                  :pre-untag 'elfeed-protocol-theoldreader-pre-untag))
  )

(provide 'elfeed-protocol-theoldreader)

;;; elfeed-protocol-theoldreader.el ends here
