# endpoints.tf — modules/core-network v0.4.0 (Plan 02-03, Task 3; CONTEXT.md
# D-22).
#
# S3 gateway VPC endpoint, attached to every private route table (both
# private-app and private-data). Attaching it to private-data specifically
# is the point: that tier has no default route to the internet at all (see
# routes.tf), so without this endpoint it could not reach S3 at all. With
# it, S3 traffic stays inside the VPC and never touches NAT or the internet
# gateway — simultaneously the security story (no internet egress needed for
# S3 access) and the cost story (no NAT data-processing charges for it).

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"

  # A gateway endpoint works by injecting a route for its AWS-managed
  # prefix list into every route table it is attached to — that is why
  # attachment here is ROUTE-TABLE-scoped, unlike an interface endpoint
  # (which attaches to subnets and gets its own ENI/IP). This is the
  # concrete detail that makes "gateway endpoint vs interface endpoint" a
  # real distinction instead of trivia.
  route_table_ids = concat(
    [for az, rt in aws_route_table.private_app : rt.id],
    [for az, rt in aws_route_table.private_data : rt.id],
  )

  tags = {
    Name = "${var.name_prefix}-${var.environment}-s3-gateway-endpoint"
  }
}

data "aws_region" "current" {}
