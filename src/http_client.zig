//! Naive, unoptimized HTTP client with a .request method that wraps Zig's HTTP
//! client fetch. Simple, and not particularly efficient. Response bodies stay
//! allocated for the lifetime of the client.

const std = @import("std");

allocator: std.mem.Allocator,
io: std.Io,
client: std.http.Client,
bearer: []const u8,
token: []const u8,

const Self = @This();
const Response = struct {
    body: []const u8,
    status: std.http.Status,
};
const Request = struct {
    url: []const u8,
    body: ?[]const u8 = null,
    headers: std.http.Client.Request.Headers = .{},
    extra_headers: []const std.http.Header = &.{},
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, token: []const u8) !Self {
    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    errdefer allocator.free(bearer);
    const cloned_token = try allocator.dupe(u8, token);
    errdefer allocator.free(cloned_token);
    return .{
        .allocator = allocator,
        .io = io,
        .client = .{ .allocator = allocator, .io = io },
        .bearer = bearer,
        .token = cloned_token,
    };
}

pub fn deinit(self: *Self) void {
    self.client.deinit();
    self.allocator.free(self.bearer);
    self.allocator.free(self.token);
}

/// Returns true for HTTP status codes that indicate a transient server-side
/// problem which is likely to succeed if retried after a short delay.
fn isTransientStatus(status: std.http.Status) bool {
    return switch (status) {
        .bad_gateway, // 502
        .service_unavailable, // 503
        .gateway_timeout, // 504
        .too_many_requests, // 429
        => true,
        else => false,
    };
}

pub fn fetch(self: *Self, request: Request, retries: isize) !Response {
    if (retries <= -1) {
        return error.TooManyRetries;
    }

    var writer =
        try std.Io.Writer.Allocating.initCapacity(self.allocator, 1024);
    var writer_initialized = true;
    errdefer if (writer_initialized) writer.deinit();
    const status = (self.client.fetch(.{
        .location = .{ .url = request.url },
        .response_writer = &writer.writer,
        .payload = request.body,
        .headers = request.headers,
        .extra_headers = request.extra_headers,
    }) catch |err| switch (err) {
        error.HttpConnectionClosing => {
            // Handle a Zig HTTP bug where keep-alive connections are closed by
            // the server after a timeout, but the client doesn't handle it
            // properly. For now we nuke the whole client (and associated
            // connection pool) and make a new one, but there might be a better
            // way to handle this.
            std.log.debug(
                "Keep alive connection closed. Initializing a new client.",
                .{},
            );
            self.client.deinit();
            self.client = .{ .allocator = self.allocator, .io = self.io };
            writer.deinit();
            writer_initialized = false;
            return self.fetch(request, retries - 1);
        },
        else => return err,
    }).status;

    // Transient server-side errors (e.g. Gateway Timeout, Bad Gateway) are
    // common when talking to the GitHub API and usually succeed on a retry.
    // Retry them here with exponential backoff so callers don't have to abort
    // the entire run over a momentary hiccup.
    if (isTransientStatus(status) and retries > 0) {
        // Exponential backoff based on how many retries have already been
        // consumed. `retries` starts high and counts down, so invert it to
        // grow the delay as attempts are exhausted (capped at ~8s).
        const attempt: u6 = @intCast(@min(@max(8 - retries, 0), 3));
        const delay_ns: u64 = @as(u64, 1_000_000_000) << attempt;
        std.log.warn(
            "Request to {s} failed with status {d} ({?s}). " ++
                "Retrying in {d}s ({d} attempt{s} left)...",
            .{
                request.url,
                @intFromEnum(status),
                status.phrase(),
                delay_ns / 1_000_000_000,
                retries,
                if (retries != 1) "s" else "",
            },
        );
        writer.deinit();
        writer_initialized = false;
        std.Thread.sleep(delay_ns);
        return self.fetch(request, retries - 1);
    }

    return .{
        .body = try writer.toOwnedSlice(),
        .status = status,
    };
}

pub fn graphql(
    self: *Self,
    body: []const u8,
    variables: anytype,
) !Response {
    const serialized = try std.json.Stringify.valueAlloc(self.allocator, .{
        .query = body,
        .variables = variables,
    }, .{});
    defer self.allocator.free(serialized);
    return try self.fetch(.{
        .url = "https://api.github.com/graphql",
        .body = serialized,
        .headers = .{
            .authorization = .{ .override = self.bearer },
            .content_type = .{ .override = "application/json" },
        },
    }, 8);
}

pub fn rest(
    self: *Self,
    url: []const u8,
) !Response {
    return try self.fetch(.{
        .url = url,
        .headers = .{
            .authorization = .{ .override = self.bearer },
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = &.{
            .{ .name = "X-GitHub-Api-Version", .value = "2026-03-10" },
        },
    }, 8);
}
