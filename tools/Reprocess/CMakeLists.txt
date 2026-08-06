
ADD_EXECUTABLE(reprocess main.cpp)

IF(MARKETSCANNER_RELEASE_BUILD)
	TARGET_COMPILE_DEFINITIONS(reprocess PRIVATE MARKETSCANNER_GIT_SHA="${MARKETSCANNER_GIT_SHA}")
ENDIF()
  
TARGET_LINK_LIBRARIES(reprocess rtabmap_core)

SET_TARGET_PROPERTIES( reprocess 
	PROPERTIES OUTPUT_NAME ${PROJECT_PREFIX}-reprocess)

INSTALL(TARGETS reprocess
		RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}" COMPONENT runtime
		BUNDLE DESTINATION "${CMAKE_BUNDLE_LOCATION}" COMPONENT runtime)

# V1R2 Gate G: shared MarketScanner factor-graph core. The SAME source
# is compiled into the iOS app (Xcode target) and into this PC
# diagnostic CLI, so both surfaces run identical native math (§11.1).
ADD_LIBRARY(marketscanner_factor_graph STATIC
	${CMAKE_CURRENT_SOURCE_DIR}/../../core/MarketScannerFactorGraph/market_scanner_factor_graph.cpp)
TARGET_INCLUDE_DIRECTORIES(marketscanner_factor_graph PUBLIC
	${CMAKE_CURRENT_SOURCE_DIR}/../../core/MarketScannerFactorGraph)
IF(SQLite3_FOUND)
	TARGET_INCLUDE_DIRECTORIES(marketscanner_factor_graph PRIVATE ${SQLite3_INCLUDE_DIRS})
	TARGET_LINK_LIBRARIES(marketscanner_factor_graph rtabmap_core ${SQLite3_LIBRARIES})
ELSE()
	TARGET_LINK_LIBRARIES(marketscanner_factor_graph rtabmap_core sqlite3)
ENDIF()

ADD_EXECUTABLE(market_scanner_graph market_scanner_graph_cli.cpp)
TARGET_LINK_LIBRARIES(market_scanner_graph marketscanner_factor_graph)
IF(MARKETSCANNER_RELEASE_BUILD)
	TARGET_COMPILE_DEFINITIONS(market_scanner_graph PRIVATE MARKETSCANNER_GIT_SHA="${MARKETSCANNER_GIT_SHA}")
ENDIF()
SET_TARGET_PROPERTIES(market_scanner_graph
	PROPERTIES OUTPUT_NAME ${PROJECT_PREFIX}-market-scanner-graph)
INSTALL(TARGETS market_scanner_graph
		RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}" COMPONENT runtime
		BUNDLE DESTINATION "${CMAKE_BUNDLE_LOCATION}" COMPONENT runtime)

# V1R3 Gate T: executable native qualification suite. Unity build: the
# test translation unit includes the core .cpp directly so internal math
# is testable; it therefore does NOT link marketscanner_factor_graph.
ADD_EXECUTABLE(market_scanner_native_tests market_scanner_native_tests.cpp)
IF(SQLite3_FOUND)
	TARGET_INCLUDE_DIRECTORIES(market_scanner_native_tests PRIVATE ${SQLite3_INCLUDE_DIRS})
	TARGET_LINK_LIBRARIES(market_scanner_native_tests rtabmap_core ${SQLite3_LIBRARIES})
ELSE()
	TARGET_LINK_LIBRARIES(market_scanner_native_tests rtabmap_core sqlite3)
ENDIF()
SET_TARGET_PROPERTIES(market_scanner_native_tests
	PROPERTIES OUTPUT_NAME ${PROJECT_PREFIX}-market-scanner-native-tests)

ADD_EXECUTABLE(prior_map_factor_graph prior_map_factor_graph.cpp)

IF(MARKETSCANNER_RELEASE_BUILD)
	TARGET_COMPILE_DEFINITIONS(prior_map_factor_graph PRIVATE MARKETSCANNER_GIT_SHA="${MARKETSCANNER_GIT_SHA}")
ENDIF()

TARGET_LINK_LIBRARIES(prior_map_factor_graph rtabmap_core)

SET_TARGET_PROPERTIES(prior_map_factor_graph
	PROPERTIES OUTPUT_NAME ${PROJECT_PREFIX}-prior-map-factor-graph)

INSTALL(TARGETS prior_map_factor_graph
		RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}" COMPONENT runtime
		BUNDLE DESTINATION "${CMAKE_BUNDLE_LOCATION}" COMPONENT runtime)

