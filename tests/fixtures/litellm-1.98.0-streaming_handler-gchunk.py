# Fixture: verbatim excerpt of litellm 1.98.0
# litellm/litellm_core_utils/streaming_handler.py lines 1185-1225 (the
# generic-streaming-chunk branch of CustomStreamWrapper._dispatch_provider_chunk).
# tests/litellm-gchunk-usage-patch.test.sh applies
# patches/litellm-1.98.0-gchunk-usage-union.patch against this file to prove the
# hunk still matches the pinned upstream shape (fleet-ops#6863). GNU patch
# tolerates the line-number offset; only the context must match.
            if self.received_finish_reason is not None:
                _chunk_has_content: Final = isinstance(chunk, dict) and (
                    bool(chunk.get("text", ""))
                    or chunk.get("tool_use") is not None
                    # Usage-only final chunks are valid and needed to surface
                    # finish_reason/usage to downstream translators.
                    or chunk.get("usage") is not None
                )
                if not _chunk_has_content and (not isinstance(chunk, dict) or "provider_specific_fields" not in chunk):
                    raise StopIteration
            anthropic_response_obj: Final[GChunk] = cast(GChunk, chunk)
            completion_obj["content"] = anthropic_response_obj["text"]
            if anthropic_response_obj["is_finished"]:
                self.received_finish_reason = anthropic_response_obj["finish_reason"]

            if anthropic_response_obj["finish_reason"]:
                self.intermittent_finish_reason = anthropic_response_obj["finish_reason"]

            if anthropic_response_obj["usage"] is not None:
                setattr(
                    model_response,
                    "usage",
                    litellm.Usage(**anthropic_response_obj["usage"]),
                )

            if "tool_use" in anthropic_response_obj and anthropic_response_obj["tool_use"] is not None:
                completion_obj["tool_calls"] = [anthropic_response_obj["tool_use"]]

            if (
                "provider_specific_fields" in anthropic_response_obj
                and anthropic_response_obj["provider_specific_fields"] is not None
            ):
                for key, value in anthropic_response_obj["provider_specific_fields"].items():
                    setattr(model_response, key, value)

            response_obj = cast(dict[str, Any], anthropic_response_obj)
        elif self.model == "replicate" or self.custom_llm_provider == "replicate":
            response_obj = self.handle_replicate_chunk(chunk)
            completion_obj["content"] = response_obj["text"]
            if response_obj["is_finished"]:
                self.received_finish_reason = response_obj["finish_reason"]
        elif self.custom_llm_provider and self.custom_llm_provider == "predibase":
            response_obj = self.handle_predibase_chunk(chunk)
            completion_obj["content"] = response_obj["text"]
            if response_obj["is_finished"]:
                self.received_finish_reason = response_obj["finish_reason"]
        elif self.custom_llm_provider and self.custom_llm_provider == "baseten":  # baseten doesn't provide streaming
            completion_obj["content"] = self.handle_baseten_chunk(chunk)
