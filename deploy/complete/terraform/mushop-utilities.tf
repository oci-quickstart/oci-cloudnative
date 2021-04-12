# Copyright (c) 2020, 2021 Oracle and/or its affiliates. All rights reserved.
# Licensed under the Universal Permissive License v 1.0 as shown at http://oss.oracle.com/licenses/upl.
# 

# Create namespace mushop-utilities for supporting services
resource "kubernetes_namespace" "cluster_utilities_namespace" {
  metadata {
    name = "mushop-utilities"
  }
  depends_on = [oci_containerengine_node_pool.oke_node_pool]
}

# MuShop Utilities helm charts

## https://github.com/prometheus-community/helm-charts/blob/main/charts/prometheus/README.md
## https://artifacthub.io/packages/helm/prometheus-community/prometheus
resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = local.helm_repository.prometheus
  chart      = "prometheus"
  version    = "13.6.0"
  namespace  = kubernetes_namespace.cluster_utilities_namespace.id
  wait       = false

  values = [
    file("${path.module}/chart-values/prometheus-values.yaml"),
  ]

  depends_on = [helm_release.ingress_nginx] # Ugly workaround because of the oci pvc provisioner not be able to wait for the node be active and retry.

  count = var.prometheus_enabled ? 1 : 0
}

## https://github.com/grafana/helm-charts/blob/main/charts/grafana/README.md
## https://artifacthub.io/packages/helm/grafana/grafana
resource "helm_release" "grafana" {
  name       = "mushop-utils-grafana" # mushop-utils included to be backwards compatible to the docs and setup chart install
  repository = local.helm_repository.grafana
  chart      = "grafana"
  version    = "6.7.3"
  namespace  = kubernetes_namespace.cluster_utilities_namespace.id
  wait       = false

  set {
    name  = "grafana\\.ini.server.root_url"
    value = "%(protocol)s://%(domain)s:%(http_port)s/grafana"
  }

  values = [
    file("${path.module}/chart-values/grafana-values.yaml"), <<EOF
datasources: 
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: Prometheus
      type: prometheus
      url: http://prometheus-server.${kubernetes_namespace.cluster_utilities_namespace.id}.svc.cluster.local
      access: proxy
      isDefault: true
      disableDeletion: true
      editable: false
    - name: Oracle Cloud Infrastructure Metrics
      type: oci-metrics-datasource
      access: proxy
      disableDeletion: true
      editable: true
      jsonData:
        tenancyOCID: ${var.tenancy_ocid}
        defaultRegion: ${var.region}
        environment: "OCI Instance"
    - name: Oracle Cloud Infrastructure Logs
      type: oci-logs-datasource
      access: proxy
      disableDeletion: true
      editable: true
      jsonData:
        tenancyOCID: ${var.tenancy_ocid}
        defaultRegion: ${var.region}
        environment: "OCI Instance"
EOF
  ]

  depends_on = [helm_release.ingress_nginx] # Ugly workaround because of the oci pvc provisioner not be able to wait for the node be active and retry.

  count = var.grafana_enabled ? 1 : 0
}

## https://github.com/helm/charts/blob/master/stable/metrics-server/README.md
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = local.helm_repository.stable
  chart      = "metrics-server"
  version    = "2.11.4"
  namespace  = kubernetes_namespace.cluster_utilities_namespace.id
  wait       = false

  values = [
    file("${path.module}/chart-values/metrics-server.yaml"),
  ]

  depends_on = [helm_release.ingress_nginx] # Ugly workaround because of the oci pvc provisioner not be able to wait for the node be active and retry.

  count = var.metrics_server_enabled ? 1 : 0
}

## https://kubernetes.github.io/ingress-nginx/
## https://artifacthub.io/packages/helm/ingress-nginx/ingress-nginx
resource "helm_release" "ingress_nginx" {
  name       = "mushop-utils-ingress-nginx" # mushop-utils included to be backwards compatible to the docs and setup chart install
  repository = local.helm_repository.ingress_nginx
  chart      = "ingress-nginx"
  version    = "3.29.0"
  namespace  = kubernetes_namespace.cluster_utilities_namespace.id
  wait       = true

  set {
    name  = "controller.metrics.enabled"
    value = true
  }

  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/oci-load-balancer-shape"
    value = var.ingress_load_balancer_shape
  }

  timeout = 1800 # workaround to wait the node be active for other charts

  depends_on = [kubernetes_deployment.cluster_autoscaler_deployment]

  count = var.ingress_nginx_enabled ? 1 : 0
}

## https://github.com/kubernetes-sigs/service-catalog/blob/master/charts/catalog/README.md
resource "helm_release" "svc-cat" {
  name       = "svc-cat"
  repository = local.helm_repository.svc_catalog
  chart      = "catalog"
  version    = "0.3.1"
  namespace  = kubernetes_namespace.cluster_utilities_namespace.id
  wait       = false

  depends_on = [helm_release.ingress_nginx] # Ugly workaround because of the oci pvc provisioner not be able to wait for the node be active and retry.

  count = var.catalog_enabled ? 1 : 0
}

## https://github.com/jetstack/cert-manager/blob/master/README.md
## https://artifacthub.io/packages/helm/jetstack/cert-manager
resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = local.helm_repository.jetstack
  chart      = "cert-manager"
  version    = "1.3.0"
  namespace  = kubernetes_namespace.cluster_utilities_namespace.id
  wait       = false

  set {
    name  = "installCRDs"
    value = true
  }

  depends_on = [helm_release.ingress_nginx] # Ugly workaround because of the oci pvc provisioner not be able to wait for the node be active and retry.

  count = var.cert_manager_enabled ? 1 : 0
}

# MuShop Datasources for outputs
## Kubernetes Service: mushop-utils-ingress-nginx-controller
data "kubernetes_service" "mushop_ingress" {
  metadata {
    name      = "mushop-utils-ingress-nginx-controller" # mushop-utils name included to be backwards compatible to the docs and setup chart install
    namespace = kubernetes_namespace.cluster_utilities_namespace.id
  }
  depends_on = [helm_release.ingress_nginx]
}

## Kubernetes Secret: Grafana Admin Password
data "kubernetes_secret" "mushop_utils_grafana" {
  metadata {
    name      = "mushop-utils-grafana"
    namespace = kubernetes_namespace.cluster_utilities_namespace.id
  }
  depends_on = [helm_release.grafana, helm_release.mushop]
}

locals {
  # Helm repos
  helm_repository = {
    stable        = "https://charts.helm.sh/stable"
    ingress_nginx = "https://kubernetes.github.io/ingress-nginx"
    jetstack      = "https://charts.jetstack.io"                        # cert-manager
    svc_catalog   = "https://kubernetes-sigs.github.io/service-catalog" # Service Catalog
    grafana       = "https://grafana.github.io/helm-charts"
    prometheus    = "https://prometheus-community.github.io/helm-charts"
  }
}