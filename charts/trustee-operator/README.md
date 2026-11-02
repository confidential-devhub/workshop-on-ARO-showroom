# Trustee Operator

Deploys the [Trustee
Operator](https://github.com/confidential-containers/trustee) via OLM on
OpenShift.

> [!NOTE]
> This chart only installs the operator. Operand resources (CRs, ConfigMaps,
> Secrets) are deployed separately via the `trustee-operands` chart.

## Requirements

- OpenShift Container Platform 4.16+
- Access to Red Hat Operator catalog (production) or custom catalog source (development)

## Installation

```bash
helm template trustee-operator charts/trustee-operator \
  | kubectl apply -f -
```

Wait for the operator to be ready before deploying operands.

## Configuration

See `values.yaml` for available options:

- **namespaceOverride**: Target namespace for the operator. The chart always creates this namespace. Defaults to the Helm release namespace if not set.
- **Production mode**: Uses official Red Hat operators catalog
- **Development mode**: Uses custom catalog source with pre-release images and mirror sets

## Uninstalling

```bash
helm template trustee-operator charts/trustee-operator | kubectl delete -f -
```
