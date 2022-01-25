# -------------------------------------------------------------
# Terraform provider configuration
# -------------------------------------------------------------
terraform {
  required_version = ">= 0.12.29"
  required_providers {
    ec = {
      source  = "elastic/ec"
      version = "0.3.0"
    }
  }
}

# -------------------------------------------------------------
# Elastic configuration
# -------------------------------------------------------------
variable "elastic_version" {
  type = string
  default = "7.16.3"
}

variable "elastic_region" {
  type = string
  default = "gcp-europe-west3"
}

variable "elastic_deployment_name" {
  type = string
  default = "Patent Analytics"
}

variable "elastic_index_name" {
  type = string
  default = "patent_publications"
}

variable "elastic_deployment_template_id" {
  type = string
  default = "gcp-io-optimized"
}

# -------------------------------------------------------------
# BigQuery configuration
# -------------------------------------------------------------
variable "google_cloud_project" {
  type = string
}

variable "google_cloud_dataflow_job_name" {
  type = string
}

variable "google_cloud_region" {
  type = string
  default = "europe-west3"
}

variable "google_cloud_container_spec_gcs_path"  {
  type = string
  default = "gs://dataflow-templates/latest/flex/BigQuery_to_Elasticsearch"
}

variable "google_cloud_inputTableSpec"  {
  type = string
}

variable "google_cloud_maxNumWorkers"  {
  type = number
  default = 20
}

# -------------------------------------------------------------
#  Deploy Elastic Cloud
# -------------------------------------------------------------
resource "ec_deployment" "elastic_deployment" {
  name                    = var.elastic_deployment_name
  region                  = var.elastic_region
  version                 = var.elastic_version
  deployment_template_id  = var.elastic_deployment_template_id
  elasticsearch {}
  kibana {}
}

output "elastic_endpoint" {
  value = ec_deployment.elastic_deployment.elasticsearch[0].https_endpoint
}

output "elastic_password" {
  value = ec_deployment.elastic_deployment.elasticsearch_password
}

output "elastic_cloud_id" {
  value = ec_deployment.elastic_deployment.elasticsearch[0].cloud_id
}

output "elastic_username" {
  value = ec_deployment.elastic_deployment.elasticsearch_username
}

output "elastic_index_name" {
  value = var.elastic_index_name
}

# -------------------------------------------------------------
# Create index mapping
# -------------------------------------------------------------
data "template_file" "index_template" {
  template = file("../json_templates/patent_analytics_publications_mapping.json")
}

data "external" "create_index" {
  query = {
    elastic_http_method = "PUT"
    elastic_endpoint    = ec_deployment.elastic_deployment.elasticsearch[0].https_endpoint
    elastic_username    = ec_deployment.elastic_deployment.elasticsearch_username
    elastic_password    = ec_deployment.elastic_deployment.elasticsearch_password
    elastic_json_body   = data.template_file.index_template.rendered
    elastic_index_name  = var.elastic_index_name
  }
  program = ["sh", "../scripts/es_create_mapping.sh" ]
  depends_on = [ec_deployment.elastic_deployment]
}

output "create_index_response" {
  value = data.external.create_index.result.acknowledged
  depends_on = [data.external.create_index]
}

# -------------------------------------------------------------
# Create Elasticsearch cluster API key for Dataflow integration
# -------------------------------------------------------------
data "template_file" "api_key_json_template" {
  template = file("../json_templates/es_api_key.json")
  vars = {
      elastic-api-key-name  = var.elastic_index_name
  }
}

data "external" "elastic_generate_api_key" {
  query = {
    elastic_endpoint  = ec_deployment.elastic_deployment.elasticsearch[0].https_endpoint
    elastic_username  = ec_deployment.elastic_deployment.elasticsearch_username
    elastic_password  = ec_deployment.elastic_deployment.elasticsearch_password
    api_key_body      = data.template_file.api_key_json_template.rendered
  }
  program = ["sh", "../scripts/es_api_key.sh" ]
  depends_on = [ec_deployment.elastic_deployment]
}

output "elastic_api_key" {
  value = data.external.elastic_generate_api_key.result.encoded
  depends_on = [data.external.elastic_generate_api_key]
}

# -------------------------------------------------------------
# Create a Dataflow job to read from BigQuery and write to Elastic
# -------------------------------------------------------------
resource "google_dataflow_flex_template_job" "read_from_bigquery_to_elasticserach" {
  project                 = var.google_cloud_project
  provider                = google-beta
  name                    = var.google_cloud_dataflow_job_name
  region                  = var.google_cloud_region
  container_spec_gcs_path = var.google_cloud_container_spec_gcs_path
  parameters = {
    connectionUrl         = ec_deployment.elastic_deployment.elasticsearch[0].cloud_id
    apiKey                = data.external.elastic_generate_api_key.result.encoded
    index                 = var.elastic_index_name
    inputTableSpec        = var.google_cloud_inputTableSpec
    maxNumWorkers         = var.google_cloud_maxNumWorkers
  }
  depends_on = [data.external.elastic_generate_api_key]
}
