import json
import os
import yaml
import sys

def main():
    models_json_path = os.getenv("MODELS_CONFIG_PATH", "../models.json")
    template_path = os.getenv("CONFIG_TEMPLATE_PATH", "config.yaml.template")
    output_path = os.getenv("CONFIG_OUTPUT_PATH", "config.yaml")
    
    node_ryzen_one = os.getenv("NODE_RYZEN_ONE", "http://amd-ai-core-one.lan:13306/v1")
    node_ryzen_two = os.getenv("NODE_RYZEN_TWO", "http://amd-ai-core-two.lan:13306/v1")
    node_mbp_mlx = os.getenv("NODE_MBP_MLX", "http://mbp-ai-core.lan:8000/v1")
    node_mbp_ollama = os.getenv("NODE_MBP_OLLAMA", "http://mbp-ai-core.lan:11434/v1")
    
    with open(models_json_path, "r") as f:
        models_data = json.load(f)
        
    with open(template_path, "r") as f:
        template_content = f.read()
        
    config = yaml.safe_load(template_content)
    if "model_list" not in config:
        config["model_list"] = []
        
    # Generate nodes
    for model in models_data.get("models", []):
        model_name = model["litellm_name"]
        rpm = model.get("rpm", 120)
        supports_reasoning = model.get("supports_reasoning", False)
        
        # MBP (Primary)
        # If it's heavy, we use MLX. If it's light, we use Ollama in the old config.
        # But we can just configure it based on what targets are available.
        if model.get("mlx_target") and model.get("is_heavy"):
            mbp_api_base = node_mbp_mlx
            mbp_target = model["mlx_target"]
        elif model.get("ollama_target"):
            mbp_api_base = node_mbp_ollama
            mbp_target = model["ollama_target"]
        else:
            mbp_api_base = node_mbp_mlx
            mbp_target = model.get("mlx_target", model["litellm_name"])
            
        mbp_entry = {
            "model_name": model_name,
            "litellm_params": {
                "model": f"openai/{mbp_target}",
                "api_base": mbp_api_base,
                "api_key": "dummy",
                "order": 1
            }
        }
        if "rpm" in model:
            mbp_entry["litellm_params"]["rpm"] = rpm
        if supports_reasoning:
            mbp_entry["model_info"] = {"supports_reasoning": True}
        config["model_list"].append(mbp_entry)
        
        # RYZEN ONE
        ryzen1_entry = {
            "model_name": model_name,
            "litellm_params": {
                "model": f"openai/{model['lemonade_target']}",
                "api_base": node_ryzen_one,
                "api_key": "dummy",
                "order": 2
            }
        }
        if not model.get("is_heavy"):
            ryzen1_entry["litellm_params"]["rpm"] = 300
        else:
            ryzen1_entry["litellm_params"]["rpm"] = 300
            
        if supports_reasoning:
            ryzen1_entry["model_info"] = {"supports_reasoning": True}
        config["model_list"].append(ryzen1_entry)
        
        # RYZEN TWO
        ryzen2_entry = {
            "model_name": model_name,
            "litellm_params": {
                "model": f"openai/{model['lemonade_target']}",
                "api_base": node_ryzen_two,
                "api_key": "dummy",
                "order": 3
            }
        }
        ryzen2_entry["litellm_params"]["rpm"] = ryzen1_entry["litellm_params"]["rpm"]
        if supports_reasoning:
            ryzen2_entry["model_info"] = {"supports_reasoning": True}
        config["model_list"].append(ryzen2_entry)

    # Sort the model list by order if needed, but litellm handles it
    
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
        
    print(f"Generated {output_path} with {len(config['model_list'])} model deployments.")

if __name__ == "__main__":
    main()
