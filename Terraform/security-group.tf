# =========================================
# CONTROL PLANE SG - base resource, no inline rules
# (inline rules referencing each other's SG id cause a
# circular dependency between the two SGs - so every rule
# below is its own aws_security_group_rule instead)
# =========================================
resource "aws_security_group" "control_plane" {
  name        = "${var.cluster_name}-control-plane-sg"
  description = "kubeadm control-plane node(s)"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-control-plane-sg"
  })
}

# =========================================
# DATA PLANE (WORKER) SG - base resource, no inline rules
# =========================================
resource "aws_security_group" "data_plane" {
  name        = "${var.cluster_name}-data-plane-sg"
  description = "kubeadm worker node(s)"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-data-plane-sg"
  })
}

# =========================================
# EGRESS - allow all outbound from both SGs
# =========================================
resource "aws_security_group_rule" "control_plane_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.control_plane.id
  description       = "Allow all outbound"
}

resource "aws_security_group_rule" "data_plane_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.data_plane.id
  description       = "Allow all outbound"
}

# =========================================================================
# CONTROL-PLANE-SG INBOUND
# =========================================================================

resource "aws_security_group_rule" "cp_ssh_from_admin" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.control_plane.id
  description       = "SSH from admin IP"
}

resource "aws_security_group_rule" "cp_api_from_data_plane" {
  type                     = "ingress"
  from_port                = 6443
  to_port                  = 6443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.data_plane.id
  security_group_id        = aws_security_group.control_plane.id
  description              = "Kubernetes API from workers"
}

resource "aws_security_group_rule" "cp_api_from_admin" {
  type              = "ingress"
  from_port         = 6443
  to_port           = 6443
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.control_plane.id
  description       = "Kubernetes API from admin IP (kubectl)"
}

resource "aws_security_group_rule" "cp_typha_from_data_plane" {
  type                     = "ingress"
  from_port                = 5473
  to_port                  = 5473
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.data_plane.id
  security_group_id        = aws_security_group.control_plane.id
  description              = "Calico Typha from workers"
}

resource "aws_security_group_rule" "cp_vxlan_from_data_plane" {
  type                     = "ingress"
  from_port                = 4789
  to_port                  = 4789
  protocol                 = "udp"
  source_security_group_id = aws_security_group.data_plane.id
  security_group_id        = aws_security_group.control_plane.id
  description              = "Calico VXLAN overlay from workers"
}

# =========================================================================
# DATA-PLANE-SG INBOUND
# =========================================================================

resource "aws_security_group_rule" "dp_ssh_from_admin" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.data_plane.id
  description       = "SSH from admin IP"
}

resource "aws_security_group_rule" "dp_kubelet_from_cp" {
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.control_plane.id
  security_group_id        = aws_security_group.data_plane.id
  description              = "Kubelet API from control plane"
}

resource "aws_security_group_rule" "dp_vxlan_from_data_plane" {
  type              = "ingress"
  from_port         = 4789
  to_port           = 4789
  protocol          = "udp"
  self              = true
  security_group_id = aws_security_group.data_plane.id
  description       = "Calico VXLAN overlay, worker to worker"
}

resource "aws_security_group_rule" "dp_vxlan_from_cp" {
  type                     = "ingress"
  from_port                = 4789
  to_port                  = 4789
  protocol                 = "udp"
  source_security_group_id = aws_security_group.control_plane.id
  security_group_id        = aws_security_group.data_plane.id
  description              = "Calico VXLAN overlay, control plane to worker"
}

resource "aws_security_group_rule" "dp_typha_from_data_plane" {
  type              = "ingress"
  from_port         = 5473
  to_port           = 5473
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.data_plane.id
  description       = "Calico Typha, worker to worker"
}

resource "aws_security_group_rule" "dp_typha_from_cp" {
  type                     = "ingress"
  from_port                = 5473
  to_port                  = 5473
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.control_plane.id
  security_group_id        = aws_security_group.data_plane.id
  description              = "Calico Typha, control plane to worker"
}

# NodePort - open to the world (as requested). Tighten to your IP once
# you're done testing - 0.0.0.0/0 on 30000-32767 means anyone can hit
# any NodePort service you expose.
resource "aws_security_group_rule" "dp_nodeport_public" {
  type              = "ingress"
  from_port         = 30000
  to_port           = 32767
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.data_plane.id
  description       = "NodePort - open to internet for demo/testing"
}