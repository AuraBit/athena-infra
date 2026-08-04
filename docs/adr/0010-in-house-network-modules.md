# 0010. In-House Network Modules, Community Module as Design Reference Only

* Status: accepted
* Date: 2026-08-04
* Deciders: Yahia Tarek (YahiaEng)
* Tier: short-form

## Context

`terraform-aws-modules/vpc/aws` is the widely-adopted community VPC
module — battle-tested across an enormous number of real production
deployments, actively maintained, and covering subnet layout, route
tables, NAT placement, and gateway endpoints with configuration surface
this estate's own `modules/core-network` reimplements from first
principles. For a real production system under a delivery deadline,
consuming that module is usually the right call, and it is not a close
question: it is free, it is more thoroughly exercised than anything one
person will build in a study project, and reinventing it costs real
engineering time for no functional gain a paying customer would notice.

The criterion that decides differently here is what this estate's product
actually is. This project's deliverable is not a working VPC — a working
VPC is table stakes — it is the ability to explain VPC internals in a
senior DevOps interview: why each subnet's CIDR is what it is, why a
route table is associated the way it is, why a NAT gateway sits where it
sits. A community module that abstracts subnet arithmetic, route-table
association, and NAT placement behind a handful of input variables hides
exactly the internals this estate exists to make explainable. Consuming it
would produce a working network and a materially weaker interview answer.

## Decision

`modules/core-network` is written in-house — its own `subnets.tf`,
`routes.tf`, `nat.tf`, `security-groups.tf`, `endpoints.tf`, and
`flow-logs.tf`, each implementing the resource shape and arithmetic
(`cidrsubnet()`, per-AZ route-table association, per-AZ or single-NAT
placement) directly rather than through a wrapping module's variables.
`terraform-aws-modules/vpc/aws` remains the **design reference**: its
conventions (subnet tiering, output naming, the shape of a well-formed VPC
module's variable surface) are deliberately borrowed where they represent
genuinely good practice, not reinvented differently for the sake of being
different.

## Consequences

* This estate carries ongoing maintenance for code it could have consumed
  for free, and the in-house module is far less battle-tested than the
  community alternative — fewer real deployments have exercised its edge
  cases, and any bug in it is a bug this project's own author must find,
  not one a wider community has already found and fixed upstream.
* Every piece of the module's internals — subnet index arithmetic, why a
  private-data route table has no default route to a NAT, why endpoints
  are gateway-type for S3 rather than interface-type — is something this
  project's author wrote, and can therefore explain from first principles
  rather than from having read someone else's variable documentation.
* A future non-study use of this pattern (a real production estate, not an
  interview-prep mockup) should very likely consume the community module
  instead — this decision's criterion is specific to what this project is
  for, not a general claim that in-house is the better engineering choice.
