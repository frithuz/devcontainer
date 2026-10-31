variable "REVISION" { default = "" }
variable "REPOSITORY_URL" { default = "" }
group "default" {
  targets = ["git"]
}
target "git" {
  context = "."
  dockerfile = "git.Dockerfile"
  target = "artifact"
  platforms = ["linux/amd64", "linux/arm64"]
  args = {
    REVISION = REVISION
    REPOSITORY_URL = REPOSITORY_URL
  }
}
