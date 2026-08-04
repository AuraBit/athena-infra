"""athena_required_tags.py -- CKV_ATHENA_1 (Plan 02-05, Task 1; CONTEXT.md
D-26, docs/tagging-standard.md).

A first-party Checkov custom check (checkov.terraform.checks.resource
.base_resource_check.BaseResourceCheck) that fails any taggable AWS resource
in this repository missing one of the six mandatory tags: Project,
Environment, Stack, ManagedBy, Owner, CostCenter. Wired into .checkov.yaml
via `external-checks-dir: checkov/custom` so the `static` CI job loads it
automatically -- no changes to .checkov.yaml's `directory` list are needed
for this file itself to be scanned by Python, only for it to be imported.

--- Why this check cannot simply "look for the six tags on every resource" --

Every env root's provider.tf sets the six mandatory tags exactly once, in
the AWS provider's `default_tags` block (see envs/dev/core-network/
provider.tf). The AWS provider merges `default_tags` into every resource
type that exposes a `tags` schema attribute, REGARDLESS of whether that
resource declares its own explicit `tags` block -- this is why almost none
of the resources in modules/core-network/*.tf write these six keys
themselves; they inherit them structurally, at apply time, through a
provider-level mechanism.

Checkov is a static HCL analyzer. It has no model of `default_tags` and
cannot evaluate what a given resource's tags will actually be once Terraform
merges the provider default with the resource's own (possibly absent)
`tags` block. A check that requires every resource to declare all six tags
explicitly would therefore fail on every resource in this repository today
-- a false positive on the committed, correctly-tagged (at apply time) tree.
A check that instead trusts every resource unconditionally would never fire
at all, including on a genuinely new resource type whose tagging behavior
under this provider has never actually been verified. Neither extreme is
the check this repository wants; D-26's own text names the trade-off
directly: "a check that fires on every resource because it cannot see
default_tags is worse than none, because it trains people to add
exclusions."

--- The design this file actually implements ------------------------------

TRUSTED_DEFAULT_TAGS_RESOURCES below is a small, explicit allowlist of AWS
resource types that THIS repository has verified default_tags genuinely
reaches -- proven empirically, once, by applying modules/core-network
against LocalStack and confirming via `terraform show -json` plus a live
`aws ec2 describe-tags` / `s3api get-bucket-tagging` call that the six
mandatory tags are present on the real, applied resource despite never
being written into that resource's own `tags` argument in HCL. A resource
of a type on this list is trusted: the check only rejects it if it
EXPLICITLY overrides one of the six mandatory keys with an empty value
(the one way a resource can defeat default_tags despite being trusted,
since an explicit resource-level tag value always wins over the provider
default on key collision).

UNVERIFIED_TAGGABLE_RESOURCES is a second, deliberately separate list:
AWS resource types this repository does not use yet, but that Phase 6's
Data/Storage and Application/Compute stacks are expected to introduce
(RDS, ElastiCache, CloudFront, EKS, IAM roles for compute). Resources of
these types ARE scanned by this check (they are in `supported_resources`
below), but are NOT trusted -- the check requires all six mandatory tags to
be explicitly present in their own `tags` argument, because this repository
has not yet proven default_tags reaches them. A future plan promotes a type
from this list into TRUSTED_DEFAULT_TAGS_RESOURCES only after doing that
same apply-and-describe proof for it, and updates this docstring's list of
verified types accordingly. This is also what makes the check demonstrably
fireable today: adding a resource of an UNVERIFIED type with an incomplete
`tags` argument on a scratch branch makes this check fail, without needing
to invent a fake "untrusted" resource type that doesn't correspond to any
real future need.

Resource types with no `tags` schema attribute at all (aws_route,
aws_route_table_association, aws_internet_gateway_attachment-style glue
resources) are simply absent from both lists and from `supported_resources`
-- Checkov never asks this check about them, correctly, since there is
nothing to tag.
"""

from typing import Any, Dict, List

from checkov.common.models.enums import CheckCategories, CheckResult
from checkov.terraform.checks.resource.base_resource_check import BaseResourceCheck

MANDATORY_TAG_KEYS = (
    "Project",
    "Environment",
    "Stack",
    "ManagedBy",
    "Owner",
    "CostCenter",
)

# Verified live against this repo's own applied state (Plan 02-05, Task 1):
# every one of these types is created by modules/core-network, applies
# successfully against LocalStack under envs/*/core-network/provider.tf's
# default_tags block, and was confirmed post-apply to carry all six
# mandatory tags without declaring them itself.
TRUSTED_DEFAULT_TAGS_RESOURCES = frozenset(
    {
        "aws_vpc",
        "aws_subnet",
        "aws_internet_gateway",
        "aws_nat_gateway",
        "aws_eip",
        "aws_route_table",
        "aws_vpc_endpoint",
        "aws_s3_bucket",
        "aws_flow_log",
        "aws_default_security_group",
        "aws_security_group",
    }
)

# Not yet used in this repo; not yet proven. Scanned, but held to the
# stricter explicit-tags standard until a future plan promotes a type above
# after doing the same apply-and-describe verification.
UNVERIFIED_TAGGABLE_RESOURCES = frozenset(
    {
        "aws_db_instance",
        "aws_elasticache_cluster",
        "aws_elasticache_replication_group",
        "aws_cloudfront_distribution",
        "aws_eks_cluster",
        "aws_iam_role",
    }
)


class AthenaRequiredTags(BaseResourceCheck):
    def __init__(self) -> None:
        name = "Ensure taggable resources carry the estate's six mandatory tags"
        check_id = "CKV_ATHENA_1"
        supported_resources = sorted(
            TRUSTED_DEFAULT_TAGS_RESOURCES | UNVERIFIED_TAGGABLE_RESOURCES
        )
        categories = [CheckCategories.CONVENTION]
        super().__init__(
            name=name,
            id=check_id,
            categories=categories,
            supported_resources=supported_resources,
        )

    def scan_resource_conf(self, conf: Dict[str, List[Any]]) -> CheckResult:
        tags_blocks = conf.get("tags")
        tags: Dict[str, Any] = {}
        if tags_blocks and isinstance(tags_blocks[0], dict):
            tags = tags_blocks[0]

        if self.entity_type in TRUSTED_DEFAULT_TAGS_RESOURCES:
            # default_tags is proven to reach this type (see module
            # docstring) -- the only way it can still be missing a mandatory
            # tag is an explicit resource-level override that blanks it,
            # since an explicit value always wins over the provider default
            # on key collision.
            blanked = [key for key in MANDATORY_TAG_KEYS if key in tags and not tags[key]]
            if blanked:
                self.evaluated_keys = [f"tags/{key}" for key in blanked]
                return CheckResult.FAILED
            self.evaluated_keys = ["tags"]
            return CheckResult.PASSED

        # Unverified type: default_tags coverage has not been proven for it
        # in this repository, so every mandatory tag must be explicit.
        missing = [key for key in MANDATORY_TAG_KEYS if not tags.get(key)]
        if missing:
            self.evaluated_keys = ["tags"]
            return CheckResult.FAILED
        self.evaluated_keys = ["tags"]
        return CheckResult.PASSED


check = AthenaRequiredTags()
