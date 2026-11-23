#!/usr/bin/env python3
"""
Validate Kubernetes label values conform to RFC 1123.
Kubernetes label values must consist of alphanumeric characters, '-', '_' or '.', 
and must start and end with an alphanumeric character.

This catches issues like app.kubernetes.io/version="6.0.1+abc123" where the '+' 
character is not allowed in Kubernetes labels.
"""
import sys
import re
from pathlib import Path
import yaml

# Kubernetes label value regex from the validation rules
# Pattern: (([A-Za-z0-9][-A-Za-z0-9_.]*)?[A-Za-z0-9])?
LABEL_PATTERN = re.compile(r'^(([A-Za-z0-9][-A-Za-z0-9_.]*)?[A-Za-z0-9])?$')


def is_valid_label_value(value):
    """Check if a label value is valid according to Kubernetes rules."""
    if not isinstance(value, str):
        return True  # Non-string values are handled by Kubernetes API
    if value == "":
        return True  # Empty strings are allowed
    return LABEL_PATTERN.match(value) is not None


def check_labels_in_manifest(file_path):
    """Check all label values in a Kubernetes manifest file."""
    errors = []
    try:
        with open(file_path, 'r') as f:
            docs = yaml.safe_load_all(f)
            for doc in docs:
                if doc is None:
                    continue
                if not isinstance(doc, dict):
                    continue
                
                metadata = doc.get('metadata', {})
                if not isinstance(metadata, dict):
                    continue
                
                labels = metadata.get('labels', {})
                if not isinstance(labels, dict):
                    continue
                
                for label_key, label_value in labels.items():
                    if not is_valid_label_value(label_value):
                        kind = doc.get('kind', 'Unknown')
                        name = metadata.get('name', 'unknown')
                        namespace = metadata.get('namespace', '')
                        full_name = f"{namespace}/{name}" if namespace else name
                        errors.append(
                            f"{file_path}: {kind} '{full_name}' has invalid label value "
                            f"'{label_key}={label_value}' (contains invalid characters)"
                        )
    except yaml.YAMLError as e:
        errors.append(f"{file_path}: YAML parse error: {e}")
    except Exception as e:
        errors.append(f"{file_path}: Error: {e}")
    
    return errors


def main():
    """Check all rendered Kubernetes manifests for invalid label values."""
    if len(sys.argv) < 2:
        print("Usage: check-k8s-labels.py <directory> [<directory> ...]")
        print("Checks all YAML files in the given directories for invalid Kubernetes labels.")
        sys.exit(1)
    
    all_errors = []
    
    for arg in sys.argv[1:]:
        path = Path(arg)
        if path.is_file():
            files = [path]
        elif path.is_dir():
            files = sorted(path.glob('**/*.yaml'))
        else:
            print(f"Error: {arg} is not a valid file or directory", file=sys.stderr)
            sys.exit(1)
        
        for yaml_file in files:
            errors = check_labels_in_manifest(yaml_file)
            all_errors.extend(errors)
    
    if all_errors:
        for error in all_errors:
            print(error, file=sys.stderr)
        sys.exit(1)
    else:
        print("✓ All Kubernetes labels are valid")
        sys.exit(0)


if __name__ == '__main__':
    main()
