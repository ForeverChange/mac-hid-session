#pragma once
#include <nlohmann/json.hpp>
#include <cmath>
#include <set>
#include <stdexcept>
#include <string>

namespace hid_session {
using json = nlohmann::json;
inline void require(bool value, const std::string& message) {
  if (!value) throw std::runtime_error(message);
}
inline void fields(const json& object, const std::set<std::string>& allowed) {
  require(object.is_object(), "expected_object");
  for (const auto& [key, value] : object.items()) {
    (void)value;
    require(allowed.contains(key), "unknown_field:" + key);
  }
}
inline bool identifier(const json& value) {
  if (!value.is_string()) return false;
  const auto s = value.get<std::string>();
  if (s.empty() || s.size() > 80) return false;
  for (unsigned char c : s)
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '-' || c == '_')) return false;
  return true;
}
inline bool allowed_app(const std::string& app) {
  return app == "com.apple.TextEdit" || app == "com.tencent.xinWeChat";
}
inline void validate(const json& q) {
  fields(q, {"id", "op", "app", "actions", "request_id"});
  require(q.contains("id") && identifier(q.at("id")), "invalid_id");
  require(q.contains("op") && q.at("op").is_string(), "invalid_op");
  const auto op = q.at("op").get<std::string>();
  if (op == "status" || op == "stop") {
    require(q.size() == 2, "unexpected_fields"); return;
  }
  if (op == "result") {
    require(q.size() == 3 && q.contains("request_id") && identifier(q.at("request_id")), "invalid_result_query"); return;
  }
  require(op == "batch", "unsupported_op");
  require(q.size() == 4 && q.contains("app") && q.at("app").is_string() &&
          allowed_app(q.at("app")), "unsupported_app");
  require(q.contains("actions") && q.at("actions").is_array() &&
          !q.at("actions").empty() && q.at("actions").size() <= 16, "invalid_batch_size");
  const std::set<std::string> keys = {"tab", "escape", "return", "left", "right", "up", "down", "backspace",
      "cmd+f", "cmd+a", "cmd+v", "cmd+c", "cmd+s", "cmd+z", "cmd+shift+s", "ctrl+f2", "test-x"};
  for (size_t i = 0; i < q.at("actions").size(); ++i) {
    const auto& a = q.at("actions").at(i);
    fields(a, {"type", "key", "x", "y", "delta", "settle_ms"});
    require(a.contains("type") && a.at("type").is_string(), "invalid_action");
    const auto type = a.at("type").get<std::string>();
    if (a.contains("settle_ms")) {
      require(a.at("settle_ms").is_number_integer(), "invalid_settle");
      require(a.at("settle_ms") >= 50 && a.at("settle_ms") <= 2000, "invalid_settle");
    }
    const auto optional = a.contains("settle_ms") ? 1u : 0u;
    if (type == "activate") {
      require(i == 0 && a.size() == 1, "activate_must_be_first_and_standalone_action");
    } else if (type == "key") {
      require(a.size() == 2 + optional && a.contains("key") && a.at("key").is_string() &&
              keys.contains(a.at("key")), "unsupported_key");
      require(a.at("key") != "test-x" || q.at("app") == "com.apple.TextEdit", "test_key_requires_TextEdit");
    } else if (type == "move" || type == "click" || type == "double-click" || type == "scroll") {
      require(a.size() == (type == "scroll" ? 4u : 3u) + optional, "invalid_pointer_fields");
      for (const auto* axis : {"x", "y"})
        require(a.contains(axis) && a.at(axis).is_number() &&
                std::isfinite(a.at(axis).get<double>()) && std::abs(a.at(axis).get<double>()) <= 100000, "invalid_coordinate");
      if (type == "scroll") {
        require(a.contains("delta") && a.at("delta").is_number_integer(), "invalid_scroll");
        require(a.at("delta") != 0 && a.at("delta") >= -100 && a.at("delta") <= 100, "invalid_scroll");
      }
    } else throw std::runtime_error("unsupported_action");
  }
}
} // namespace hid_session
