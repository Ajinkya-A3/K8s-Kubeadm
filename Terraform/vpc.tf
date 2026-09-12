# =========================================
# VPC
# =========================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr # 10.0.0.0/16
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-vpc"
  })
}

# =========================================
# INTERNET GATEWAY
# =========================================
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-igw"
  })
}

# =========================================
# AVAILABILITY ZONES - all AZs in the current region
# =========================================
data "aws_availability_zones" "available" {
  state = "available"
}

# =========================================
# PUBLIC SUBNETS - one per AZ
# With a /16 VPC CIDR, cidrsubnet(cidr, 8, n) carves out /24s:
# 10.0.0.0/24, 10.0.1.0/24, 10.0.2.0/24, ...
# =========================================
resource "aws_subnet" "public" {
  count = length(data.aws_availability_zones.available.names)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-public-${data.aws_availability_zones.available.names[count.index]}"
  })
}

# =========================================
# PUBLIC ROUTE TABLE (single, shared by all public subnets)
# =========================================
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-public-rt"
  })
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_assoc" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}