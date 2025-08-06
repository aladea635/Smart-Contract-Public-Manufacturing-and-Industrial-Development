;; Manufacturing Equipment Certification Contract
;; Verifies safety and compliance of industrial machinery and processes

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u400))
(define-constant ERR-EQUIPMENT-NOT-FOUND (err u401))
(define-constant ERR-CERTIFICATION-NOT-FOUND (err u402))
(define-constant ERR-INVALID-INPUT (err u403))
(define-constant ERR-CERTIFICATION-EXPIRED (err u404))
(define-constant ERR-ALREADY-CERTIFIED (err u405))

;; Data Variables
(define-data-var equipment-counter uint u0)
(define-data-var certification-counter uint u0)
(define-data-var inspection-counter uint u0)

;; Equipment status constants
(define-constant EQUIPMENT-REGISTERED u1)
(define-constant EQUIPMENT-CERTIFIED u2)
(define-constant EQUIPMENT-SUSPENDED u3)
(define-constant EQUIPMENT-DECOMMISSIONED u4)

;; Certification status constants
(define-constant CERT-PENDING u1)
(define-constant CERT-APPROVED u2)
(define-constant CERT-REJECTED u3)
(define-constant CERT-EXPIRED u4)

;; Data Maps
(define-map equipment-registry
  { equipment-id: uint }
  {
    owner: principal,
    manufacturer: (string-ascii 100),
    model: (string-ascii 100),
    serial-number: (string-ascii 50),
    equipment-type: (string-ascii 50),
    installation-date: uint,
    status: uint,
    last-inspection: (optional uint),
    next-inspection-due: (optional uint)
  }
)

(define-map certifications
  { certification-id: uint }
  {
    equipment-id: uint,
    certifier: principal,
    certification-type: (string-ascii 50),
    issued-date: uint,
    expiry-date: uint,
    status: uint,
    compliance-standards: (string-ascii 200)
  }
)

(define-map inspections
  { inspection-id: uint }
  {
    equipment-id: uint,
    inspector: principal,
    inspection-date: uint,
    inspection-type: (string-ascii 50),
    passed: bool,
    findings: (string-ascii 500),
    next-inspection-date: uint
  }
)

(define-map authorized-certifiers principal bool)
(define-map authorized-inspectors principal bool)

;; Authorization functions
(define-private (is-authorized-certifier (user principal))
  (or (is-eq user CONTRACT-OWNER)
      (default-to false (map-get? authorized-certifiers user))))

(define-private (is-authorized-inspector (user principal))
  (or (is-eq user CONTRACT-OWNER)
      (default-to false (map-get? authorized-inspectors user))))

;; Public functions

;; Register equipment
(define-public (register-equipment
  (manufacturer (string-ascii 100))
  (model (string-ascii 100))
  (serial-number (string-ascii 50))
  (equipment-type (string-ascii 50))
  (installation-date uint))
  (let ((equipment-id (+ (var-get equipment-counter) u1)))
    (asserts! (> (len manufacturer) u0) ERR-INVALID-INPUT)
    (asserts! (> (len model) u0) ERR-INVALID-INPUT)
    (asserts! (> (len serial-number) u0) ERR-INVALID-INPUT)
    (asserts! (<= installation-date block-height) ERR-INVALID-INPUT)
    (map-set equipment-registry
      { equipment-id: equipment-id }
      {
        owner: tx-sender,
        manufacturer: manufacturer,
        model: model,
        serial-number: serial-number,
        equipment-type: equipment-type,
        installation-date: installation-date,
        status: EQUIPMENT-REGISTERED,
        last-inspection: none,
        next-inspection-due: none
      }
    )
    (var-set equipment-counter equipment-id)
    (ok equipment-id)))

;; Apply for equipment certification
(define-public (apply-for-certification
  (equipment-id uint)
  (certification-type (string-ascii 50))
  (compliance-standards (string-ascii 200)))
  (let ((equipment (unwrap! (map-get? equipment-registry { equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-FOUND))
        (certification-id (+ (var-get certification-counter) u1)))
    (asserts! (is-eq tx-sender (get owner equipment)) ERR-NOT-AUTHORIZED)
    (asserts! (> (len certification-type) u0) ERR-INVALID-INPUT)
    (map-set certifications
      { certification-id: certification-id }
      {
        equipment-id: equipment-id,
        certifier: tx-sender,
        certification-type: certification-type,
        issued-date: block-height,
        expiry-date: (+ block-height u52560), ;; ~1 year in blocks
        status: CERT-PENDING,
        compliance-standards: compliance-standards
      }
    )
    (var-set certification-counter certification-id)
    (ok certification-id)))

;; Issue certification
(define-public (issue-certification (certification-id uint) (approved bool))
  (let ((certification (unwrap! (map-get? certifications { certification-id: certification-id }) ERR-CERTIFICATION-NOT-FOUND))
        (equipment (unwrap! (map-get? equipment-registry { equipment-id: (get equipment-id certification) }) ERR-EQUIPMENT-NOT-FOUND)))
    (asserts! (is-authorized-certifier tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status certification) CERT-PENDING) ERR-INVALID-INPUT)

    ;; Update certification status
    (map-set certifications
      { certification-id: certification-id }
      (merge certification {
        status: (if approved CERT-APPROVED CERT-REJECTED),
        certifier: tx-sender
      })
    )

    ;; Update equipment status if approved
    (if approved
      (map-set equipment-registry
        { equipment-id: (get equipment-id certification) }
        (merge equipment { status: EQUIPMENT-CERTIFIED })
      )
      true
    )

    (ok true)))

;; Conduct equipment inspection
(define-public (conduct-inspection
  (equipment-id uint)
  (inspection-type (string-ascii 50))
  (passed bool)
  (findings (string-ascii 500))
  (next-inspection-blocks uint))
  (let ((equipment (unwrap! (map-get? equipment-registry { equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-FOUND))
        (inspection-id (+ (var-get inspection-counter) u1))
        (next-inspection-date (+ block-height next-inspection-blocks)))
    (asserts! (is-authorized-inspector tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (> next-inspection-blocks u0) ERR-INVALID-INPUT)

    ;; Record inspection
    (map-set inspections
      { inspection-id: inspection-id }
      {
        equipment-id: equipment-id,
        inspector: tx-sender,
        inspection-date: block-height,
        inspection-type: inspection-type,
        passed: passed,
        findings: findings,
        next-inspection-date: next-inspection-date
      }
    )

    ;; Update equipment inspection dates
    (map-set equipment-registry
      { equipment-id: equipment-id }
      (merge equipment {
        last-inspection: (some block-height),
        next-inspection-due: (some next-inspection-date),
        status: (if passed (get status equipment) EQUIPMENT-SUSPENDED)
      })
    )

    (var-set inspection-counter inspection-id)
    (ok inspection-id)))

;; Update equipment status
(define-public (update-equipment-status (equipment-id uint) (new-status uint))
  (let ((equipment (unwrap! (map-get? equipment-registry { equipment-id: equipment-id }) ERR-EQUIPMENT-NOT-FOUND)))
    (asserts! (or (is-eq tx-sender (get owner equipment)) (is-authorized-inspector tx-sender)) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= new-status EQUIPMENT-REGISTERED) (<= new-status EQUIPMENT-DECOMMISSIONED)) ERR-INVALID-INPUT)
    (map-set equipment-registry
      { equipment-id: equipment-id }
      (merge equipment { status: new-status })
    )
    (ok true)))

;; Add authorized certifier
(define-public (add-authorized-certifier (certifier principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (map-set authorized-certifiers certifier true)
    (ok true)))

;; Add authorized inspector
(define-public (add-authorized-inspector (inspector principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (map-set authorized-inspectors inspector true)
    (ok true)))

;; Read-only functions

;; Get equipment details
(define-read-only (get-equipment (equipment-id uint))
  (map-get? equipment-registry { equipment-id: equipment-id }))

;; Get certification details
(define-read-only (get-certification (certification-id uint))
  (map-get? certifications { certification-id: certification-id }))

;; Get inspection details
(define-read-only (get-inspection (inspection-id uint))
  (map-get? inspections { inspection-id: inspection-id }))

;; Check if certification is valid
(define-read-only (is-certification-valid (certification-id uint))
  (match (map-get? certifications { certification-id: certification-id })
    certification (and (is-eq (get status certification) CERT-APPROVED)
                      (> (get expiry-date certification) block-height))
    false))

;; Check authorization status
(define-read-only (is-certifier (user principal))
  (is-authorized-certifier user))

(define-read-only (is-inspector (user principal))
  (is-authorized-inspector user))

;; Get counters
(define-read-only (get-counters)
  {
    equipment-counter: (var-get equipment-counter),
    certification-counter: (var-get certification-counter),
    inspection-counter: (var-get inspection-counter)
  })
