//
//  RocketReserverTests.swift
//  RocketReserverTests
//
//  Created by AlexPan on 2025/12/11.
//

import XCTest
@testable import Apollo
@testable import ApolloAPI
import ApolloTestSupport
import RocketReserver
import RocketReserverAPI

// MARK: - Mock URL Protocol

public struct MockNetworkInterceptorProvider: Apollo.InterceptorProvider {
  public let mockData: Data

  public init(
    _ mockData: Data
  ) {
    self.mockData = mockData
  }

    public func httpInterceptors<Operation: GraphQLOperation>(for operation: Operation) -> [any Apollo.HTTPInterceptor] {
    return DefaultInterceptorProvider.shared.httpInterceptors(for: operation) + [
      MockNetworkFetchInterceptor(mockData: mockData),
    ]
  }
}

struct MockNetworkFetchInterceptor: Apollo.HTTPInterceptor {

    let mockData: Data

    func intercept(
      request: URLRequest,
      next: NextHTTPInterceptorFunction
    ) async throws -> HTTPResponse {
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!

        let stream: AsyncThrowingStream<Data, any Error> = .executingInAsyncTask { continuation in
          continuation.yield(mockData)
          continuation.finish()
        }
        let chunks: NonCopyableAsyncThrowingStream<Data> = .init(stream: stream)
        return HTTPResponse(
          response: response,
          chunks: chunks
        )
    }

}



// MARK: - Tests

final class RocketReserverTests: XCTestCase {

    
    /// Test case to reproduce the thread-safety crash in InMemoryNormalizedCache
    ///
    /// This test reproduces the crash reported in:
    /// Issue: b27e5bf5e74faa9993ea4d075e5af28e
    ///
    /// The crash occurs when multiple GraphQL queries execute concurrently and try to merge
    /// records into the same InMemoryNormalizedCache simultaneously, causing memory corruption
    /// in Dictionary operations (RecordSet.merge(record:)).
    ///
    /// Stack trace shows:
    /// - RecordSet.merge(record:) -> Dictionary.setValue(_:forKey:isUnique:)
    /// - Dictionary.copy() -> Memory corruption crash
    ///
    /// Expected behavior: This test may crash or fail due to thread-safety issues in
    /// InMemoryNormalizedCache when multiple threads access it concurrently.
    ///
    @MainActor
    func test_concurrentCacheMerge_threadSafetyIssue() async throws {
        // Given: Create a shared ApolloStore with InMemoryNormalizedCache (default)
        // This simulates the real-world scenario where multiple queries share the same cache
        let sharedStore = ApolloStore()
        
        // Create mock response for LaunchListQuery
        let launchListQueryJson = """
        {
          "data": {
            "__typename": "Query",
            "launches": {
              "__typename": "LaunchConnection",
              "hasMore": true,
              "cursor": "cursor123",
              "launches": [
                {
                  "__typename": "Launch",
                  "id": "1",
                  "site": "CCAFS SLC 40",
                  "mission": {
                    "__typename": "Mission",
                    "name": "FalconSat",
                    "missionPatch": "https://images2.imgbox.com/40/e3/GypSkayF_o.png"
                  }
                },
                {
                  "__typename": "Launch",
                  "id": "2",
                  "site": "VAFB SLC 4E",
                  "mission": {
                    "__typename": "Mission",
                    "name": "DemoSat",
                    "missionPatch": "https://images2.imgbox.com/be/e7/iNqsqVYM_o.png"
                  }
                }
              ]
            }
          }
        }
        """.data(using: .utf8)!
        
        // Create multiple ApolloClient instances sharing the same store
        func makeApolloClientWithSharedStore(mockData: Data) -> ApolloClient {
            let interceptorProvider = MockNetworkInterceptorProvider(mockData)
            let endpointURL = URL(string: "https://apollo-fullstack-tutorial.herokuapp.com/graphql")!
            
            let networkTransport = RequestChainNetworkTransport(
                urlSession: URLSession.shared,
                interceptorProvider: interceptorProvider,
                store: sharedStore, // Use shared store
                endpointURL: endpointURL
            )
            
            return ApolloClient(networkTransport: networkTransport, store: sharedStore) // Use shared store
        }
        
        let apolloClient = makeApolloClientWithSharedStore(mockData: launchListQueryJson)
        
        // When: Execute multiple queries concurrently from different threads
        // Using networkOnly policy - Apollo will still write responses to cache,
        // triggering concurrent cache merge operations that cause the crash
        let numberOfConcurrentQueries = 1000 // Increase to make crash more likely
        
        // Use actor-safe counter to track completed tasks
        actor TaskCounter {
            private var completedCount = 0
            
            func increment() {
                completedCount += 1
            }
            
            func getCount() -> Int {
                completedCount
            }
        }
        
        let counter = TaskCounter()
        
        // Execute all queries concurrently and wait for all to complete
        await withTaskGroup(of: Void.self) { group in
            // Add all tasks to the group
            for _ in 0..<numberOfConcurrentQueries {
                group.addTask {
                    do {
                        // Use networkOnly - Apollo will still write to cache, triggering merge operations
                        // Execute on different threads to maximize concurrency
                        _ = try await apolloClient.fetch(
                            query: LaunchListQuery(cursor: .null),
                            cachePolicy: .networkOnly
                        )
                        await counter.increment()
                    } catch {
                        // Ignore errors for this stress test, but still count as completed
                        await counter.increment()
                    }
                }
            }
            
            // Wait for all tasks to complete
            // withTaskGroup automatically waits for all tasks when the closure exits
        }
        
        // Then: Verify all tasks completed and check if we reached here without crashing
        let completedCount = await counter.getCount()
        XCTAssertEqual(
            completedCount,
            numberOfConcurrentQueries,
            "All \(numberOfConcurrentQueries) concurrent queries should have completed. Only \(completedCount) completed."
        )
        
        // If we reach here without crashing, the test passes
        // However, this test is designed to potentially expose the thread-safety issue
        // The actual crash would occur during the concurrent cache merge operations above
        XCTAssertTrue(true, "Test completed - if crash occurred, it would have happened during concurrent cache operations")
    }

}
