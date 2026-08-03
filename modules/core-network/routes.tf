# routes.tf — modules/core-network v0.3.0 (Plan 02-03, Task 2; CONTEXT.md
# D-22).
#
# One shared public route table, and one private-app + one private-data
# route table PER AVAILABILITY ZONE — the per-AZ split for the private tiers
# is what lets each AZ's private-app subnet route to its own AZ's NAT
# gateway once single_nat_gateway is false, without touching this file.
# Every subnet is associated with exactly one route table.

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-${var.environment}-public-rt"
    Tier = "public"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = toset(var.availability_zones)

  subnet_id      = local.subnet_ids_by_tier_and_az["public-${each.value}"]
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private_app" {
  for_each = toset(var.availability_zones)

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-${var.environment}-private-app-rt-${substr(each.value, -1, 1)}"
    Tier = "private-app"
  }
}

resource "aws_route" "private_app_nat" {
  for_each = toset(var.availability_zones)

  route_table_id         = aws_route_table.private_app[each.value].id
  destination_cidr_block = "0.0.0.0/0"
  # Under single_nat_gateway, every AZ's private-app route table points at
  # the one shared NAT (local.nat_azs[0]); otherwise each AZ points at its
  # own NAT — "the NAT gateway serving its AZ".
  nat_gateway_id = aws_nat_gateway.this[var.single_nat_gateway ? local.nat_azs[0] : each.value].id
}

resource "aws_route_table_association" "private_app" {
  for_each = toset(var.availability_zones)

  subnet_id      = local.subnet_ids_by_tier_and_az["private-app-${each.value}"]
  route_table_id = aws_route_table.private_app[each.value].id
}

resource "aws_route_table" "private_data" {
  for_each = toset(var.availability_zones)

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-${var.environment}-private-data-rt-${substr(each.value, -1, 1)}"
    Tier = "private-data"
  }
}

# Deliberately NO aws_route resource for private_data: this tier gets no
# default route to the internet at all. That absence is the tier's whole
# purpose (the strongest trust boundary in the topology, per the threat
# model) — a reader seeing only the route table and its one local VPC route
# would otherwise read the missing 0.0.0.0/0 route as an omission rather
# than the deliberate design it is. This plan's own Task 3 (S3 gateway
# endpoint) is the one exception this tier gets, and it works by injecting a
# route into these same route tables without ever touching NAT or the
# internet gateway.
resource "aws_route_table_association" "private_data" {
  for_each = toset(var.availability_zones)

  subnet_id      = local.subnet_ids_by_tier_and_az["private-data-${each.value}"]
  route_table_id = aws_route_table.private_data[each.value].id
}
