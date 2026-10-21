data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = [for i in range(2) : cidrsubnet(var.vpc_cidr, 8, i)]     # /24
  private_subnets = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i + 1)] # /20, room for VPC CNI pod IPs

  # Everything that lives inside the VPC (except subnets and the IGW) takes its
  # VPC/subnet IDs from the cleanup null_resource. That forces this destroy order:
  #   EKS, fck-nat, route tables  ->  GuardDuty cleanup  ->  subnets, IGW  ->  VPC
  vpc_id             = null_resource.vpc_guardduty_cleanup.triggers.vpc_id
  public_subnet_ids  = split(",", null_resource.vpc_guardduty_cleanup.triggers.public_subnet_ids)
  private_subnet_ids = split(",", null_resource.vpc_guardduty_cleanup.triggers.private_subnet_ids)
}

resource "aws_vpc" "this" {
  #checkov:skip=CKV2_AWS_11:VPC flow logs not required for a short-lived demo environment
  #checkov:skip=CKV2_AWS_12:Default SG is locked down by aws_default_security_group.this (vpc_id via the cleanup resource, which checkov cannot resolve)
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.prefix}-vpc"
  }
}

# Lock down the default SG (no rules) so nothing uses it by accident.
resource "aws_default_security_group" "this" {
  vpc_id = local.vpc_id

  tags = {
    Name = "${var.prefix}-default-deny"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name                     = "${var.prefix}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name                              = "${var.prefix}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = local.vpc_id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = local.public_subnet_ids[count.index]
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = local.vpc_id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.fck_nat.primary_network_interface_id
  }

  tags = {
    Name = "${var.prefix}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = local.private_subnet_ids[count.index]
  route_table_id = aws_route_table.private.id
}

# -----------------------------------------------------------------------------
# fck-nat: t4g.nano ARM64 NAT instance instead of a NAT Gateway (~$30/mo saved)
# -----------------------------------------------------------------------------

data "aws_ami" "fck_nat" {
  most_recent = true
  owners      = ["568608671756"] # fck-nat publisher

  filter {
    name   = "name"
    values = ["fck-nat-al2023-*-arm64-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_security_group" "fck_nat" {
  name_prefix = "${var.prefix}-fck-nat-"
  #checkov:skip=CKV_AWS_382:NAT instance must forward all egress from private subnets to the internet
  description = "fck-nat instance: forward traffic from private subnets"
  vpc_id      = local.vpc_id

  ingress {
    description = "All traffic from private subnets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = local.private_subnets
  }

  egress {
    description = "All outbound (NAT to internet)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.prefix}-fck-nat"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "fck_nat" {
  #checkov:skip=CKV_AWS_88:NAT instance needs a public IP to forward private-subnet egress
  #checkov:skip=CKV_AWS_126:Detailed monitoring not needed for a demo NAT instance
  #checkov:skip=CKV2_AWS_41:fck-nat needs no AWS API access, so no instance profile
  ami                         = data.aws_ami.fck_nat.id
  instance_type               = "t4g.nano"
  subnet_id                   = local.public_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.fck_nat.id]
  associate_public_ip_address = true
  source_dest_check           = false
  ebs_optimized               = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.prefix}-fck-nat"
  }

  depends_on = [aws_route_table_association.public]
}

# -----------------------------------------------------------------------------
# GuardDuty cleanup (destroy-time)
#
# GuardDuty Runtime Monitoring auto-creates a VPC endpoint, ENIs and the
# GuardDutyManagedSecurityGroup-<vpc-id> SG in every VPC. They are not in
# Terraform state and block subnet/VPC deletion with DependencyViolation.
# Order: endpoints -> ENIs (poll up to 3 min) -> non-default SGs (retry every
# 30 s for up to 5 min). SG deletion errors are retried, never swallowed; the
# provisioner fails if SGs remain so the problem is visible.
# -----------------------------------------------------------------------------

resource "null_resource" "vpc_guardduty_cleanup" {
  triggers = {
    vpc_id             = aws_vpc.this.id
    public_subnet_ids  = join(",", aws_subnet.public[*].id)
    private_subnet_ids = join(",", aws_subnet.private[*].id)
    region             = var.aws_region
    profile            = var.aws_profile
  }

  # Destroyed before the subnets and IGW so GuardDuty endpoint ENIs are gone first.
  depends_on = [aws_subnet.public, aws_subnet.private, aws_internet_gateway.this]

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -u
      VPC_ID="${self.triggers.vpc_id}"
      REGION="${self.triggers.region}"
      PROFILE="${self.triggers.profile}"
      AWS_ARGS=(--region "$REGION")
      if [ -n "$PROFILE" ]; then
        AWS_ARGS+=(--profile "$PROFILE")
      fi

      # 1. Delete VPC endpoints (e.g. GuardDuty runtime monitoring)
      ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'VpcEndpoints[].VpcEndpointId' \
        --output text "$${AWS_ARGS[@]}")
      if [ -n "$ENDPOINTS" ] && [ "$ENDPOINTS" != "None" ]; then
        echo "Deleting VPC endpoints: $ENDPOINTS"
        aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $ENDPOINTS "$${AWS_ARGS[@]}"
        sleep 15
      fi

      # 2. Poll for ENIs (up to 3 minutes). Delete available ones; force-detach
      #    and delete in-use ENIs not owned by AWS services. Failures inside the
      #    loop are expected while instances terminate and are retried next pass.
      echo "Polling for ENIs in VPC $VPC_ID (up to 3 minutes)..."
      MAX_WAIT=180
      WAITED=0
      while [ $WAITED -lt $MAX_WAIT ]; do
        ALL_ENIS=$(aws ec2 describe-network-interfaces \
          --filters "Name=vpc-id,Values=$VPC_ID" \
          --query 'NetworkInterfaces[].NetworkInterfaceId' \
          --output text "$${AWS_ARGS[@]}")
        if [ -z "$ALL_ENIS" ] || [ "$ALL_ENIS" = "None" ]; then
          echo "All ENIs cleared."
          break
        fi

        AVAIL_ENIS=$(aws ec2 describe-network-interfaces \
          --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
          --query 'NetworkInterfaces[].NetworkInterfaceId' \
          --output text "$${AWS_ARGS[@]}")
        for ENI in $AVAIL_ENIS; do
          [ "$ENI" = "None" ] && continue
          echo "Deleting available ENI: $ENI"
          aws ec2 delete-network-interface --network-interface-id "$ENI" "$${AWS_ARGS[@]}" \
            || echo "  ENI $ENI not deletable yet, will retry"
        done

        INUSE_ENIS=$(aws ec2 describe-network-interfaces \
          --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=in-use" \
          --query 'NetworkInterfaces[?RequesterManaged==`false`].[NetworkInterfaceId,Attachment.AttachmentId]' \
          --output text "$${AWS_ARGS[@]}")
        while IFS=$'\t' read -r ENI ATTACHMENT; do
          [ -z "$ENI" ] && continue
          if [ -n "$ATTACHMENT" ] && [ "$ATTACHMENT" != "None" ]; then
            echo "Force-detaching ENI $ENI (attachment $ATTACHMENT)..."
            aws ec2 detach-network-interface --attachment-id "$ATTACHMENT" --force "$${AWS_ARGS[@]}" \
              || echo "  detach of $ENI failed, will retry"
            sleep 5
          fi
          aws ec2 delete-network-interface --network-interface-id "$ENI" "$${AWS_ARGS[@]}" \
            || echo "  ENI $ENI not deletable yet, will retry"
        done <<< "$INUSE_ENIS"

        echo "ENIs still present, waiting 15s ($${WAITED}s elapsed)..."
        sleep 15
        WAITED=$((WAITED + 15))
      done

      # 3. Delete non-default SGs, retrying every 30 s for up to 5 minutes.
      #    GuardDuty releases its SG references only after instances fully terminate.
      MAX_SG_WAIT=300
      SG_WAITED=0
      while true; do
        SG_IDS=$(aws ec2 describe-security-groups \
          --filters "Name=vpc-id,Values=$VPC_ID" \
          --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
          --output text "$${AWS_ARGS[@]}")
        if [ -z "$SG_IDS" ] || [ "$SG_IDS" = "None" ]; then
          echo "All non-default SGs deleted."
          break
        fi
        if [ $SG_WAITED -ge $MAX_SG_WAIT ]; then
          echo "ERROR: security groups still present after $${MAX_SG_WAIT}s: $SG_IDS" >&2
          exit 1
        fi
        for SG in $SG_IDS; do
          echo "Deleting security group: $SG"
          if ! aws ec2 delete-security-group --group-id "$SG" "$${AWS_ARGS[@]}"; then
            echo "  SG $SG still has references, will retry..."
          fi
        done
        echo "Waiting 30s before re-checking SGs ($${SG_WAITED}s elapsed)..."
        sleep 30
        SG_WAITED=$((SG_WAITED + 30))
      done
    EOT
  }
}
