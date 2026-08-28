terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

variable "members" {
  default = ["chohyeonseo", "jeongjihyun", "jooeunbin", "kimseoyeon",
  "kimyena", "parkseonghyeon", "sungyujeong", "kwonminchan"]
}

resource "kubernetes_namespace_v1" "member_ns" {
  for_each = toset(var.members)
  metadata {
    name = "ns-${each.value}"
  }
}

resource "kubernetes_role_v1" "namespace_admin" {
  for_each = toset(var.members)
  metadata {
    name      = "namespace-admin"
    namespace = kubernetes_namespace_v1.member_ns[each.key].metadata[0].name
  }
  rule {
    api_groups = ["", "apps", "batch"]
    resources  = ["*"]
    verbs      = ["*"]
  }
}
