;; Industrial Waste Management Contract
;; Monitors and regulates disposal of manufacturing byproducts and hazardous materials

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-FACILITY-NOT-FOUND (err u301))
(define-constant ERR-WASTE-RECORD-NOT-FOUND (err u302))
(define-constant ERR-INVALID-INPUT (err u303))
(define-constant ERR-COMPLIANCE-VIOLATION (err u304))
(define-constant ERR-FACILITY-NOT-CERTIFIED (err u305))

;; Data Variables
(define-data-var facility-counter uint u0)
(define-data-var waste-record-counter uint u0)
(define-data-var violation-counter uint u0)

;; Facility status constants
(define-constant FACILITY-ACTIVE u1)
(define-constant FACILITY-SUSPENDED u2)
(define-constant FACILITY-REVOKED u3)

;; Waste type constants
(define-constant WASTE-HAZARDOUS u1)
(define-constant WASTE-NON-HAZARDOUS u2)
(define-constant WASTE-RECYCLABLE u3)

;; Data Maps
(define-map waste-facilities
  { facility-id: uint }
  {
    operator: principal,
    name: (string-ascii 100),
    location: (string-ascii 100),
    facility-type: (string-ascii 50),
    capacity-tons: uint,
    current-load: uint,
    certification-expires: uint,
    status: uint,
    registered-at: uint
  }
)

(define-map waste-records
  { record-id: uint }
  {
    generator: principal,
    facility-id: uint,
    waste-type: uint,
    quantity-tons: uint,
    disposal-method: (string-ascii 50),
    disposal-date: uint,
    compliance-verified: bool,
    verification-date: (optional uint)
  }
)

(define-map compliance-violations
  { violation-id: uint }
  {
    facility-id: uint,
    violation-type: (string-ascii 100),
    severity: uint,
    reported-at: uint,
    resolved: bool,
    resolution-date: (optional uint),
    penalty-amount: uint
  }
)

(define-map authorized-inspectors principal bool)

(define-map generator-registrations principal bool)

;; Authorization functions
(define-private (is-authorized-inspector (user principal))
  (or (is-eq user CONTRACT-OWNER)
      (default-to false (map-get? authorized-inspectors user))))

(define-private (is-registered-generator (user principal))
  (default-to false (map-get? generator-registrations user)))

;; Public functions

;; Register as a waste generator
(define-public (register-waste-generator)
  (begin
    (map-set generator-registrations tx-sender true)
    (ok true)))

;; Register a waste treatment facility
(define-public (register-waste-facility
  (name (string-ascii 100))
  (location (string-ascii 100))
  (facility-type (string-ascii 50))
  (capacity-tons uint)
  (certification-expires uint))
  (let ((facility-id (+ (var-get facility-counter) u1)))
    (asserts! (> (len name) u0) ERR-INVALID-INPUT)
    (asserts! (> capacity-tons u0) ERR-INVALID-INPUT)
    (asserts! (> certification-expires block-height) ERR-INVALID-INPUT)
    (map-set waste-facilities
      { facility-id: facility-id }
      {
        operator: tx-sender,
        name: name,
        location: location,
        facility-type: facility-type,
        capacity-tons: capacity-tons,
        current-load: u0,
        certification-expires: certification-expires,
        status: FACILITY-ACTIVE,
        registered-at: block-height
      }
    )
    (var-set facility-counter facility-id)
    (ok facility-id)))

;; Record waste disposal
(define-public (record-waste-disposal
  (facility-id uint)
  (waste-type uint)
  (quantity-tons uint)
  (disposal-method (string-ascii 50)))
  (let ((facility (unwrap! (map-get? waste-facilities { facility-id: facility-id }) ERR-FACILITY-NOT-FOUND))
        (record-id (+ (var-get waste-record-counter) u1)))
    (asserts! (is-registered-generator tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status facility) FACILITY-ACTIVE) ERR-FACILITY-NOT-CERTIFIED)
    (asserts! (> (get certification-expires facility) block-height) ERR-FACILITY-NOT-CERTIFIED)
    (asserts! (and (>= waste-type WASTE-HAZARDOUS) (<= waste-type WASTE-RECYCLABLE)) ERR-INVALID-INPUT)
    (asserts! (> quantity-tons u0) ERR-INVALID-INPUT)
    (asserts! (<= (+ (get current-load facility) quantity-tons) (get capacity-tons facility)) ERR-INVALID-INPUT)

    ;; Create waste record
    (map-set waste-records
      { record-id: record-id }
      {
        generator: tx-sender,
        facility-id: facility-id,
        waste-type: waste-type,
        quantity-tons: quantity-tons,
        disposal-method: disposal-method,
        disposal-date: block-height,
        compliance-verified: false,
        verification-date: none
      }
    )

    ;; Update facility load
    (map-set waste-facilities
      { facility-id: facility-id }
      (merge facility { current-load: (+ (get current-load facility) quantity-tons) })
    )

    (var-set waste-record-counter record-id)
    (ok record-id)))

;; Verify compliance of waste disposal
(define-public (verify-compliance (record-id uint))
  (let ((record (unwrap! (map-get? waste-records { record-id: record-id }) ERR-WASTE-RECORD-NOT-FOUND)))
    (asserts! (is-authorized-inspector tx-sender) ERR-NOT-AUTHORIZED)
    (map-set waste-records
      { record-id: record-id }
      (merge record {
        compliance-verified: true,
        verification-date: (some block-height)
      })
    )
    (ok true)))

;; Report compliance violation
(define-public (report-violation
  (facility-id uint)
  (violation-type (string-ascii 100))
  (severity uint)
  (penalty-amount uint))
  (let ((violation-id (+ (var-get violation-counter) u1)))
    (asserts! (is-authorized-inspector tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-some (map-get? waste-facilities { facility-id: facility-id })) ERR-FACILITY-NOT-FOUND)
    (asserts! (and (>= severity u1) (<= severity u5)) ERR-INVALID-INPUT)
    (map-set compliance-violations
      { violation-id: violation-id }
      {
        facility-id: facility-id,
        violation-type: violation-type,
        severity: severity,
        reported-at: block-height,
        resolved: false,
        resolution-date: none,
        penalty-amount: penalty-amount
      }
    )
    (var-set violation-counter violation-id)
    (ok violation-id)))

;; Update facility status
(define-public (update-facility-status (facility-id uint) (new-status uint))
  (let ((facility (unwrap! (map-get? waste-facilities { facility-id: facility-id }) ERR-FACILITY-NOT-FOUND)))
    (asserts! (is-authorized-inspector tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= new-status FACILITY-ACTIVE) (<= new-status FACILITY-REVOKED)) ERR-INVALID-INPUT)
    (map-set waste-facilities
      { facility-id: facility-id }
      (merge facility { status: new-status })
    )
    (ok true)))

;; Add authorized inspector
(define-public (add-authorized-inspector (inspector principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (map-set authorized-inspectors inspector true)
    (ok true)))

;; Read-only functions

;; Get facility information
(define-read-only (get-waste-facility (facility-id uint))
  (map-get? waste-facilities { facility-id: facility-id }))

;; Get waste record
(define-read-only (get-waste-record (record-id uint))
  (map-get? waste-records { record-id: record-id }))

;; Get violation details
(define-read-only (get-violation (violation-id uint))
  (map-get? compliance-violations { violation-id: violation-id }))

;; Check if user is authorized inspector
(define-read-only (is-inspector (user principal))
  (is-authorized-inspector user))

;; Check if user is registered generator
(define-read-only (is-generator (user principal))
  (is-registered-generator user))

;; Get counters
(define-read-only (get-counters)
  {
    facility-counter: (var-get facility-counter),
    waste-record-counter: (var-get waste-record-counter),
    violation-counter: (var-get violation-counter)
  })
