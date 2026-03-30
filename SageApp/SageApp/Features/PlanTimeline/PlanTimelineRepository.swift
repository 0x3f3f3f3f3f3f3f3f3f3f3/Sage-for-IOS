import Foundation

@MainActor
struct PlanTimelineRepository {
    func loadTimeline(start: Date, end: Date, using environment: AppEnvironment) async throws -> [TimelineBlockDTO] {
        let formatter = DateFormatter.makeOffsetISO8601()
        let path = makeAPIPath(
            "/api/mobile/v1/timeline",
            queryItems: [
                URLQueryItem(name: "start", value: formatter.string(from: start)),
                URLQueryItem(name: "end", value: formatter.string(from: end))
            ]
        )
        let payload: [TimelineBlockDTO] = try await environment.apiClient.send(path: path)
        return payload
    }

    func loadTasks(using environment: AppEnvironment) async throws -> [TaskDTO] {
        let payload: [TaskDTO] = try await environment.apiClient.send(path: "/api/mobile/v1/tasks")
        return payload
    }

    func createTimeBlock(taskId: String, request: TimeBlockWriteRequest, using environment: AppEnvironment) async throws -> TimeBlockDTO {
        let payload: TimeBlockDTO = try await environment.apiClient.send(
            path: "/api/mobile/v1/tasks/\(taskId)/time-blocks",
            method: "POST",
            body: request
        )
        return payload
    }

    func updateTimeBlock(id: String, request: TimeBlockWriteRequest, using environment: AppEnvironment) async throws -> TimeBlockDTO {
        let payload: TimeBlockDTO = try await environment.apiClient.send(
            path: "/api/mobile/v1/time-blocks/\(id)",
            method: "PATCH",
            body: request
        )
        return payload
    }

    func deleteTimeBlock(id: String, using environment: AppEnvironment) async throws {
        let _: EmptySuccessDTO = try await environment.apiClient.send(
            path: "/api/mobile/v1/time-blocks/\(id)",
            method: "DELETE",
            body: EmptyBody()
        )
    }

    func loadTask(id: String, using environment: AppEnvironment) async throws -> TaskDTO {
        let payload: TaskDTO = try await environment.apiClient.send(path: "/api/mobile/v1/tasks/\(id)")
        return payload
    }
}
