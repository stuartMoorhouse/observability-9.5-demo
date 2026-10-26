module "eks" {
  #checkov:skip=CKV_TF_1:Registry module pinned by version constraint and lock file
  #checkov:skip=CKV_AWS_38:Public endpoint required for kubectl/helm from the presenter laptop; restricted to cluster_endpoint_public_access_cidrs (operator IP /32 by default)
  #checkov:skip=CKV_AWS_39:Public endpoint intentional for this demo (see CKV_AWS_38)
  #checkov:skip=CKV_AWS_37:Only audit logs enabled to limit CloudWatch cost on a short-lived demo
  #checkov:skip=CKV_AWS_338:7-day log retention is sufficient for a short-lived demo
  #checkov:skip=CKV_AWS_58:False positive; secrets encryption is enabled by the module (create_kms_key default)
  #checkov:skip=CKV_AWS_79:False positive; node launch template sets http_tokens = required
  #checkov:skip=CKV_AWS_341:Hop limit 2 required for pods (EBS CSI, OTel) to reach IMDSv2 on nodes
  #checkov:skip=CKV_AWS_111:Module-internal IPv6 CNI policy, not used (IPv4 cluster)
  #checkov:skip=CKV_AWS_356:Module-internal IPv6 CNI policy, not used (IPv4 cluster)
  #checkov:skip=CKV2_AWS_5:Cluster SG is attached to the EKS cluster by the module
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.prefix
  kubernetes_version = var.kubernetes_version

  # Public endpoint so kubectl/helm work from the presenter's laptop.
  endpoint_public_access       = true
  endpoint_private_access      = true
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # Access entry granting cluster-admin to the identity running Terraform.
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API"

  # Subnet IDs taken from the route table associations so nodes only launch once
  # the fck-nat default route exists (they need egress to join the cluster).
  vpc_id                   = local.vpc_id
  subnet_ids               = aws_route_table_association.private[*].subnet_id
  control_plane_subnet_ids = aws_route_table_association.private[*].subnet_id

  # Keep CloudWatch cost low: audit log only, short retention.
  enabled_log_types                      = ["audit"]
  cloudwatch_log_group_retention_in_days = 7

  # Secrets envelope encryption with a module-managed KMS key.
  kms_key_deletion_window_in_days = 7

  addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true
    }
    # Uses the node role (AmazonEBSCSIDriverPolicy attached below) for PVCs (Postgres).
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    # On-demand, not spot: a spot reclaim mid-demo reschedules pods in front of the customer.
    default = {
      name            = "${var.prefix}-nodes"
      use_name_prefix = true

      ami_type       = var.node_architecture == "arm64" ? "AL2023_ARM_64_STANDARD" : "AL2023_x86_64_STANDARD"
      capacity_type  = "ON_DEMAND"
      instance_types = coalesce(var.node_instance_types, var.node_architecture == "arm64" ? ["m7g.large"] : ["m6i.large"])

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_disk_size_gb
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }

      iam_role_additional_policies = {
        ebs_csi = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      }

      # provider default_tags do not reach launch template tag_specifications. The
      # account denies ec2:RunInstances without the org tags on the request, so
      # node launches fail unless the tags are set on the template explicitly.
      launch_template_tags = var.tags
    }
  }

  tags = {
    Name = var.prefix
  }
}

data "aws_partition" "current" {}

# Write/refresh the local kubeconfig so scripts, kubectl and helm work.
resource "null_resource" "update_kubeconfig" {
  triggers = {
    cluster_name = module.eks.cluster_name
    endpoint     = module.eks.cluster_endpoint
    region       = var.aws_region
    profile      = var.aws_profile
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "aws eks update-kubeconfig --name '${self.triggers.cluster_name}' --region '${self.triggers.region}' --profile '${self.triggers.profile}' --alias '${self.triggers.cluster_name}'"
  }

  depends_on = [module.eks]
}
