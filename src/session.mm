// A bounded, local-only DriverKit session. No shell, text, database or network RPC.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <pqrs/karabiner/driverkit/virtual_hid_device_driver.hpp>
#include <pqrs/karabiner/driverkit/virtual_hid_device_service.hpp>
#include "protocol.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
#include <fcntl.h>
#include <iostream>
#include <libproc.h>
#include <map>
#include <memory>
#include <poll.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

using namespace std::chrono_literals;
using hid_session::json;
using hid_session::require;
namespace service = pqrs::karabiner::driverkit::virtual_hid_device_service;
namespace report = pqrs::karabiner::driverkit::virtual_hid_device_driver::hid_report;
using Clock = std::chrono::steady_clock;
static volatile std::sig_atomic_t interrupted = 0;
static constexpr const char* daemon_path = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon";

static std::string foreground() {
  @autoreleasepool {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    NSString* value = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
    return value ? value.UTF8String : "";
  }
}
static CGPoint pointer() {
  auto event = CGEventCreate(nullptr);
  require(event != nullptr, "cursor_unavailable");
  const CGPoint p = CGEventGetLocation(event);
  CFRelease(event);
  return p;
}
static json displays() {
  uint32_t count = 0;
  require(CGGetActiveDisplayList(0, nullptr, &count) == kCGErrorSuccess && count > 0 && count <= 16, "display_unavailable");
  std::vector<CGDirectDisplayID> ids(count);
  require(CGGetActiveDisplayList(count, ids.data(), &count) == kCGErrorSuccess, "display_unavailable");
  json out = json::array();
  std::sort(ids.begin(), ids.end());
  for (auto id : ids) {
    auto r = CGDisplayBounds(id);
    out.push_back({{"id", id}, {"x", r.origin.x}, {"y", r.origin.y}, {"width", r.size.width}, {"height", r.size.height}});
  }
  return out;
}
static bool in_displays(double x, double y, const json& geometry) {
  for (const auto& d : geometry)
    if (x >= d.at("x").get<double>() + 3 && y >= d.at("y").get<double>() + 3 &&
        x < d.at("x").get<double>() + d.at("width").get<double>() - 3 &&
        y < d.at("y").get<double>() + d.at("height").get<double>() - 3) return true;
  return false;
}
static uid_t console_uid() {
  struct stat st{};
  require(stat("/dev/console", &st) == 0, "console_unavailable");
  return st.st_uid;
}
static bool daemon_exists() {
  int count = proc_listallpids(nullptr, 0);
  require(count > 0, "process_inventory_unavailable");
  std::vector<pid_t> pids(static_cast<size_t>(count) + 256);
  count = proc_listallpids(pids.data(), static_cast<int>(pids.size() * sizeof(pid_t)));
  for (int i = 0; i < count && i < static_cast<int>(pids.size()); ++i) {
    char path[PROC_PIDPATHINFO_MAXSIZE]{};
    if (proc_pidpath(pids[i], path, sizeof(path)) > 0 && std::string(path) == daemon_path) return true;
  }
  return false;
}

struct Backend {
  bool simulated;
  uid_t owner;
  std::unique_ptr<service::client> client;
  std::atomic<bool> keyboard_ready{false}, mouse_ready{false}, failed{false};
  std::atomic<unsigned> connection_count{0};
  pid_t daemon = -1;
  int lock_fd = -1;
  bool dispatcher_started = false;
  json geometry;
  std::string fake_front = "com.apple.TextEdit";
  CGPoint fake_cursor{500, 400};
  Clock::time_point request_deadline{};
  unsigned reports = 0;

  Backend(bool fake, uid_t uid) : simulated(fake), owner(uid) {}
  void start() {
    geometry = simulated ? json::array({{{"id", 1}, {"x", 0}, {"y", 0}, {"width", 1920}, {"height", 1080}}}) : displays();
    if (simulated) {keyboard_ready = mouse_ready = true; connection_count = 1; return;}
    require(geteuid() == 0 && owner >= 500 && console_uid() == owner, "root_and_console_owner_required");
    lock_fd = open("/private/var/run/mac-hid-session.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    require(lock_fd >= 0 && flock(lock_fd, LOCK_EX | LOCK_NB) == 0, "another_session_running");
    require(!daemon_exists(), "existing_Karabiner_daemon_do_not_take_over");
    daemon = fork();
    require(daemon >= 0, "daemon_fork_failed");
    if (daemon == 0) {
      int fd = open("/dev/null", O_RDWR);
      if (fd >= 0) {dup2(fd, 0); dup2(fd, 1); dup2(fd, 2); if (fd > 2) close(fd);}
      execl(daemon_path, daemon_path, static_cast<char*>(nullptr));
      _exit(127);
    }
    pqrs::dispatcher::extra::initialize_shared_dispatcher();
    dispatcher_started = true;
    client = std::make_unique<service::client>();
    client->connected.connect([this] {
      if (++connection_count != 1) {failed = true; return;}
      service::virtual_hid_keyboard_parameters parameters;
      parameters.set_country_code(pqrs::hid::country_code::us);
      client->async_virtual_hid_keyboard_initialize(parameters);
      client->async_virtual_hid_pointing_initialize();
    });
    // Initial connection retries are handled by upstream; no reconnect after a successful connection.
    client->closed.connect([this] {if (connection_count) failed = true;});
    client->error_occurred.connect([this](auto&&) {failed = true;});
    client->driver_version_mismatched.connect([this](bool value) {if (value) failed = true;});
    client->virtual_hid_keyboard_ready.connect([this](bool value) {keyboard_ready = value;});
    client->virtual_hid_pointing_ready.connect([this](bool value) {mouse_ready = value;});
    client->async_start();
    const auto until = Clock::now() + 15s;
    while ((!keyboard_ready || !mouse_ready) && !failed && !interrupted && Clock::now() < until) {
      require(waitpid(daemon, nullptr, WNOHANG) == 0, "official_daemon_exited");
      std::this_thread::sleep_for(25ms);
    }
    require(keyboard_ready && mouse_ready && !failed && !interrupted, "devices_not_ready");
    std::this_thread::sleep_for(1000ms); // Once per session, never once per action.
  }
  std::string front() const {return simulated ? fake_front : foreground();}
  CGPoint cursor() const {return simulated ? fake_cursor : pointer();}
  void guard(const std::string& app, bool check_front = true) {
    require(!interrupted && !failed && keyboard_ready && mouse_ready, "session_or_device_stopped");
    require(Clock::now() < request_deadline, "batch_deadline");
    if (!simulated) {
      require(console_uid() == owner, "console_owner_changed");
      require(displays() == geometry, "display_geometry_changed_restart_session");
    }
    if (check_front) require(front() == app, "foreground_mismatch");
  }
  void wait_checked(const std::string& app, int ms) {
    const auto until = Clock::now() + std::chrono::milliseconds(ms);
    do {guard(app); if (simulated) return; std::this_thread::sleep_for(10ms);} while (Clock::now() < until);
  }
  void neutral() {
    if (client) {client->async_post_report(report::keyboard_input{}); client->async_post_report(report::pointing_input{});}
  }
  void key(const std::string& app, const std::string& name) {
    static const std::map<std::string, uint16_t> usages = {{"tab", 43}, {"escape", 41}, {"return", 40},
      {"left", 80}, {"right", 79}, {"up", 82}, {"down", 81}, {"backspace", 42},
      {"cmd+f", 9}, {"cmd+a", 4}, {"cmd+v", 25}, {"cmd+c", 6}, {"cmd+s", 22},
      {"cmd+z", 29}, {"cmd+shift+s", 22}, {"ctrl+f2", 59}, {"test-x", 27}};
    report::keyboard_input down;
    down.keys.insert(usages.at(name));
    if (name.starts_with("cmd+")) down.modifiers.insert(report::modifier::left_command);
    if (name == "cmd+shift+s") down.modifiers.insert(report::modifier::left_shift);
    if (name == "ctrl+f2") down.modifiers.insert(report::modifier::left_control);
    guard(app);
    if (client) client->async_post_report(down);
    ++reports;
    try {wait_checked(app, 80);} catch (...) {neutral(); throw;}
    if (client) client->async_post_report(report::keyboard_input{});
    ++reports;
  }
  void move(const std::string& app, double x, double y) {
    require(in_displays(x, y, geometry), "point_outside_display");
    unsigned stagnant = 0;
    auto previous = cursor();
    for (unsigned i = 0; i < 120; ++i) {
      guard(app);
      auto p = cursor();
      const double dx = x - p.x, dy = y - p.y;
      if (std::abs(dx) <= 3 && std::abs(dy) <= 3) return;
      if (i && p.x == previous.x && p.y == previous.y) require(++stagnant < 4, "cursor_not_moving");
      else stagnant = 0;
      previous = p;
      auto delta = [](double v) {return std::abs(v) <= 2 ? 0 : std::clamp(static_cast<int>(std::lround(v * 0.5)), -30, 30);};
      report::pointing_input r;
      r.x = static_cast<uint8_t>(static_cast<int8_t>(delta(dx)));
      r.y = static_cast<uint8_t>(static_cast<int8_t>(delta(dy)));
      if (client) client->async_post_report(r);
      else fake_cursor = CGPointMake(p.x + delta(dx), p.y + delta(dy));
      ++reports;
      wait_checked(app, 60); // Preserve the motion cadence of the verified route.
    }
    throw std::runtime_error("cursor_target_not_reached");
  }
  void activate(const std::string& app) {
    guard(app, false);
    if (simulated) {fake_front = app; return;}
    @autoreleasepool {
      auto running = [NSRunningApplication runningApplicationsWithBundleIdentifier:[NSString stringWithUTF8String:app.c_str()]];
      require(running.count == 1 && [running.firstObject activateWithOptions:0], "target_not_running");
    }
    const auto until = Clock::now() + 3s;
    while (front() != app && Clock::now() < until) {guard(app, false); std::this_thread::sleep_for(25ms);}
    guard(app);
  }
  void run(const std::string& app, const json& a) {
    const auto type = a.at("type").get<std::string>();
    if (type == "activate") {activate(app); return;}
    guard(app);
    if (type == "key") key(app, a.at("key"));
    else {
      move(app, a.at("x"), a.at("y"));
      if (type != "move") {
        const int count = type == "double-click" ? 2 : 1;
        for (int i = 0; i < count; ++i) {
          guard(app);
          report::pointing_input r;
          if (type == "scroll") r.vertical_wheel = static_cast<uint8_t>(static_cast<int8_t>(a.at("delta").get<int>()));
          else r.buttons.insert(1);
          if (client) client->async_post_report(r);
          ++reports;
          try {wait_checked(app, 80);} catch (...) {neutral(); throw;}
          if (client) client->async_post_report(report::pointing_input{});
          ++reports;
          if (i + 1 < count) wait_checked(app, 90);
        }
      }
    }
    wait_checked(app, a.value("settle_ms", 150));
  }
  ~Backend() {
    neutral();
    if (client) {std::this_thread::sleep_for(100ms); client.reset();}
    if (dispatcher_started) pqrs::dispatcher::extra::terminate_shared_dispatcher();
    if (daemon > 0 && waitpid(daemon, nullptr, WNOHANG) == 0) {
      kill(daemon, SIGTERM);
      auto until = Clock::now() + 3s;
      while (waitpid(daemon, nullptr, WNOHANG) == 0 && Clock::now() < until) std::this_thread::sleep_for(25ms);
      if (waitpid(daemon, nullptr, WNOHANG) == 0) {kill(daemon, SIGKILL); waitpid(daemon, nullptr, 0);}
    }
    if (lock_fd >= 0) close(lock_fd);
  }
};

struct Socket {
  int fd = -1;
  std::string path;
  bool bound = false;
  ~Socket() {if (fd >= 0) close(fd); if (bound) unlink(path.c_str());}
};
struct RuntimeCleanup {
  std::string directory;
  ~RuntimeCleanup() {
    if (directory.empty()) return;
    // Only our fixed, root-owned, per-session files; never follow a caller-supplied cleanup list.
    for (const auto* name : {"control.sock", "hid-session", "events.log"}) unlink((directory + "/" + name).c_str());
    rmdir(directory.c_str());
  }
};
static std::string receive_line(int fd) {
  const auto until = Clock::now() + 2s;
  std::string input;
  while (Clock::now() < until && !interrupted) {
    pollfd p{fd, POLLIN, 0};
    if (poll(&p, 1, 100) <= 0) continue;
    char buf[1024];
    ssize_t n = recv(fd, buf, sizeof(buf), 0);
    require(n > 0, "incomplete_request");
    input.append(buf, static_cast<size_t>(n));
    require(input.size() <= 16384, "request_too_large");
    if (input.find('\n') != std::string::npos) {
      require(input.find('\n') == input.size() - 1, "one_request_per_connection");
      return input;
    }
  }
  throw std::runtime_error("request_timeout");
}
static void respond(int fd, const json& value) {
  const std::string data = value.dump() + "\n";
  size_t sent = 0;
  const auto until = Clock::now() + 2s;
  while (sent < data.size() && Clock::now() < until) {
    pollfd p{fd, POLLOUT, 0};
    if (poll(&p, 1, 100) <= 0) continue;
    auto n = send(fd, data.data() + sent, data.size() - sent, MSG_DONTWAIT);
    if (n <= 0) return;
    sent += static_cast<size_t>(n);
  }
}
static void serve(const std::string& path, uid_t uid, bool simulated, int lifetime, int idle, unsigned limit) {
  require(path.size() < sizeof(sockaddr_un::sun_path) && path.starts_with('/'), "invalid_socket_path");
  const std::string parent = path.substr(0, path.find_last_of('/'));
  struct stat st{};
  require(lstat(parent.c_str(), &st) == 0 && S_ISDIR(st.st_mode), "socket_directory_required");
  if (simulated) require(st.st_uid == uid && (st.st_mode & 0077) == 0, "private_owner_directory_required");
  else require(st.st_uid == 0 && (st.st_mode & 0022) == 0, "root_owned_socket_directory_required");
  require(lstat(path.c_str(), &st) != 0 && errno == ENOENT, "socket_path_already_exists");
  require(simulated ? geteuid() != 0 && uid == getuid() : geteuid() == 0, "invalid_server_uid");
  Backend backend(simulated, uid);
  backend.start();
  Socket server;
  server.path = path;
  server.fd = socket(AF_UNIX, SOCK_STREAM, 0);
  require(server.fd >= 0, "socket_failed");
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  strlcpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path));
  require(bind(server.fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0, "bind_failed");
  server.bound = true;
  require(chmod(path.c_str(), 0600) == 0, "socket_permissions_failed");
  if (!simulated) require(chown(path.c_str(), uid, -1) == 0, "socket_owner_failed");
  require(listen(server.fd, 4) == 0, "listen_failed");
  const auto started = Clock::now(), hard_end = started + std::chrono::seconds(lifetime);
  auto last_action = started;
  unsigned actions = 0;
  std::map<std::string, std::pair<json, json>> results;
  std::string stopped = "stopped";
  std::cout << json({{"event", "ready"}, {"simulated", simulated}, {"pid", getpid()}, {"socket", path}}).dump() << std::endl;
  while (!interrupted && !backend.failed) {
    if (Clock::now() >= hard_end) {stopped = "lifetime_limit"; break;}
    if (Clock::now() - last_action >= std::chrono::seconds(idle)) {stopped = "idle_limit"; break;}
    if (actions >= limit) {stopped = "action_limit"; break;}
    if (!simulated && console_uid() != uid) {stopped = "console_owner_changed"; break;}
    pollfd poller{server.fd, POLLIN, 0};
    if (poll(&poller, 1, 100) <= 0) continue;
    int fd = accept(server.fd, nullptr, nullptr);
    if (fd < 0) continue;
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    uid_t peer; gid_t group;
    if (getpeereid(fd, &peer, &group) != 0 || peer != uid) {respond(fd, {{"ok", false}, {"error", "peer_uid_mismatch"}}); close(fd); continue;}
    bool stop = false;
    try {
      const auto q = json::parse(receive_line(fd));
      hid_session::validate(q); // Validate the entire batch before any input.
      const auto id = q.at("id").get<std::string>(), op = q.at("op").get<std::string>();
      if (auto found = results.find(id); found != results.end()) {
        require(found->second.first == q, "request_id_reused_with_different_content");
        auto cached = found->second.second; cached["replayed_result"] = true;
        respond(fd, cached); close(fd); continue;
      }
      json result = {{"id", id}, {"ok", true}, {"simulated", simulated}};
      if (op == "status") {
        auto p = backend.cursor();
        result.update({{"pid", getpid()}, {"front_app", backend.front()}, {"cursor", {p.x, p.y}}, {"displays", backend.geometry},
          {"actions", actions}, {"reports", backend.reports}, {"device_initializations", backend.connection_count.load()},
          {"hard_remaining_seconds", std::max(0.0, std::chrono::duration<double>(hard_end - Clock::now()).count())},
          {"idle_remaining_seconds", std::max(0.0, idle - std::chrono::duration<double>(Clock::now() - last_action).count())}});
      } else if (op == "result") {
        auto found = results.find(q.at("request_id").get<std::string>());
        result["found"] = found != results.end();
        if (found != results.end()) result["result"] = found->second.second;
      } else if (op == "stop") stop = true;
      else {
        require(actions + q.at("actions").size() <= limit, "batch_exceeds_action_budget");
        require(results.size() < 1000, "request_cache_limit");
        // Check all coordinates against the session geometry before the first action.
        for (const auto& a : q.at("actions")) if (a.contains("x"))
          require(in_displays(a.at("x"), a.at("y"), backend.geometry), "point_outside_display");
        const auto begin = Clock::now();
        backend.request_deadline = std::min(hard_end, begin + 30s);
        json timings = json::array();
        unsigned completed = 0;
        for (const auto& a : q.at("actions")) {
          const auto step_start = Clock::now();
          const unsigned before = backend.reports;
          try {backend.run(q.at("app"), a); ++completed;}
          catch (const std::exception& e) {
            backend.neutral();
            result["ok"] = false; result["error"] = e.what();
            result["partial_input_possible"] = backend.reports > before;
            timings.push_back({{"type", a.at("type")}, {"ok", false}, {"reports", backend.reports - before}});
            ++actions; break;
          }
          ++actions;
          timings.push_back({{"type", a.at("type")}, {"ok", true}, {"reports", backend.reports - before},
            {"elapsed_ms", std::chrono::duration<double, std::milli>(Clock::now() - step_start).count()}});
        }
        if (completed) last_action = Clock::now();
        result["completed"] = completed;
        result["timings"] = timings;
        result["elapsed_ms"] = std::chrono::duration<double, std::milli>(Clock::now() - begin).count();
        result["device_initializations"] = backend.connection_count.load();
        // Store success and partial failure before replying; a lost reply must not replay input.
        results.emplace(id, std::make_pair(q, result));
      }
      respond(fd, result);
    } catch (const std::exception& e) {respond(fd, {{"ok", false}, {"error", e.what()}});}
    close(fd);
    if (stop) {stopped = "requested"; break;}
  }
  std::cout << json({{"event", "closed"}, {"reason", stopped}, {"actions", actions}, {"simulated", simulated}}).dump() << std::endl;
}

int main(int argc, char** argv) {
  std::signal(SIGTERM, [](int) {interrupted = 1;});
  std::signal(SIGINT, [](int) {interrupted = 1;});
  std::signal(SIGPIPE, SIG_IGN);
  @autoreleasepool {
    try {
      if (argc == 2 && std::string(argv[1]) == "--validate") {
        std::string input; std::getline(std::cin, input);
        require(input.size() <= 16384, "request_too_large");
        hid_session::validate(json::parse(input));
        std::cout << "{\"ok\":true,\"input_posted\":false}\n"; return 0;
      }
      if (argc == 2 && std::string(argv[1]) == "--inspect") {
        auto p = pointer();
        std::cout << json({{"front_app", foreground()}, {"cursor", {p.x, p.y}}, {"displays", displays()}, {"input_posted", false}}).dump() << '\n'; return 0;
      }
      if (argc != 14 || (std::string(argv[1]) != "--serve" && std::string(argv[1]) != "--simulate")) {
        std::cout << "mac-hid-session: no input.\n--inspect | --validate (JSON stdin)\n--serve|--simulate --socket PATH --uid UID --lifetime SECONDS --idle SECONDS --max-actions N --protocol 1\n";
        return argc == 1 ? 0 : 2;
      }
      require(std::string(argv[2]) == "--socket" && std::string(argv[4]) == "--uid" && std::string(argv[6]) == "--lifetime" &&
              std::string(argv[8]) == "--idle" && std::string(argv[10]) == "--max-actions" && std::string(argv[12]) == "--protocol" && std::string(argv[13]) == "1", "invalid_arguments");
      int owner = std::stoi(argv[5]), lifetime = std::stoi(argv[7]), idle = std::stoi(argv[9]), limit = std::stoi(argv[11]);
      require(owner >= 500 && lifetime >= 1 && lifetime <= 7200 && idle >= 1 && idle <= 1800 && idle <= lifetime && limit >= 1 && limit <= 500, "invalid_session_limits");
      const bool simulated = std::string(argv[1]) == "--simulate";
      RuntimeCleanup runtime;
      if (!simulated) {
        const std::string path = argv[3];
        const std::string directory = path.substr(0, path.find_last_of('/'));
        const std::string prefix = "/private/tmp/mac-hid-session.";
        struct stat st{};
        require(path == directory + "/control.sock" && directory.starts_with(prefix) &&
                hid_session::identifier(directory.substr(prefix.size())) && lstat(directory.c_str(), &st) == 0 &&
                S_ISDIR(st.st_mode) && st.st_uid == 0 && (st.st_mode & 0022) == 0, "invalid_root_runtime_directory");
        runtime.directory = directory;
      }
      serve(argv[3], static_cast<uid_t>(owner), simulated, lifetime, idle, static_cast<unsigned>(limit));
      return 0;
    } catch (const std::exception& e) {
      std::cerr << json({{"ok", false}, {"error", e.what()}}).dump() << '\n'; return 1;
    }
  }
}
