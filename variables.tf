variable "region" {
  description = "AWS region where resources will be created"
  type        = string
}

variable "name_prefix" {
  description = "Prefix used for naming all resources"
  type        = string
}

variable "project_tag" {
  description = "Value for the Project tag applied to all resources"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the launch template"
  type        = string
}
