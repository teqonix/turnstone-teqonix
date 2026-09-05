import json
import os
import yaml
import sys

def main():
    models_json_path = os.getenv("MODELS_CONFIG_PATH", "../models.json")
    template_path = os.getenv("CONFIG_TEMPLATE_PATH", "config.yaml.template")
    output_path = os.getenv("CONFIG_OUTPUT_PATH", "config.yaml")
    
    pair_api_base = os.getenv("PAIR_API_BASE", "http://127.0.0.1:11434")
    
    with open(models_json_path, "r") as f:
        models_data = json.load(f)
        
    with open(template_path, "r") as f:
        template_content = f.read()
        
    config = yaml.safe_load(template_content)
    if "model_list" not in config:
        config["model_list"] = []
        
    # Generate model deployments for PAIR
    for model in models_data.get("models", []):
        model_name = model["litellm_name"]
        supports_reasoning = model.get("supports_reasoning", False)
        ollama_target = model.get("ollama_target", model_name)
        
        entry = {
            "model_name": model_name,
            "litellm_params": {
                "model": f"ollama/{ollama_target}",
                "api_base": pair_api_base
            }
        }
        if supports_reasoning:
            entry["model_info"] = {"supports_reasoning": True}
            
        config["model_list"].append(entry)

    with open(output_path, "w") as f:
        # Write template header comments first
        header_comments = []
        for line in template_content.splitlines():
            if line.startswith("#"):
                header_comments.append(line)
            else:
                break
        f.write("\n".join(header_comments) + "\n\n")
        yaml.dump(config, f, default_flow_style=False, sort_keys=False)
        
    print(f"Generated {output_path} with {len(config['model_list'])} model deployments targeting PAIR at {pair_api_base}.")

if __name__ == "__main__":
    main()
