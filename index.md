# Polaris Security Helm repository

helm repo add polaris https://polaris-security.github.io/helm
helm repo update
helm install polaris polaris/polaris -f my-values.yaml
