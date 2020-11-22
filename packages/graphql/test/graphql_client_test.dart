import 'dart:convert';

import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'package:test/test.dart';
import 'package:mockito/mockito.dart';

import 'package:graphql/client.dart';
import 'package:gql/language.dart';
import './mutation_sequence_issue_data.dart' as order;

import './helpers.dart';

class MockLink extends Mock implements Link {}

void main() {
  const String readSingle = r'''
    query ReadSingle($id: ID!) {
      single(id: $id) {
        id,
        __typename,
        name
      }
    }
  ''';

  const String writeSingle = r'''
    mutation WriteSingle($id: ID!, $name: String!) {
      updateSingle(id: $id, name: $name) {
        id,
        __typename,
        name
      }
    }
  ''';

  const String readRepositories = r'''
    query ReadRepositories($nRepositories: Int!) {
      viewer {
        repositories(last: $nRepositories) {
          nodes {
            __typename
            id
            name
            viewerHasStarred
          }
        }
      }
    }
  ''';
  readRepositoryData({withTypenames = true, withIds = true}) {
    return {
      'viewer': {
        'repositories': {
          'nodes': [
            {
              if (withIds) 'id': 'MDEwOlJlcG9zaXRvcnkyNDgzOTQ3NA==',
              'name': 'pq',
              'viewerHasStarred': false
            },
            {
              if (withIds) 'id': 'MDEwOlJlcG9zaXRvcnkzMjkyNDQ0Mw==',
              'name': 'go-evercookie',
              'viewerHasStarred': false
            },
            {
              if (withIds) 'id': 'MDEwOlJlcG9zaXRvcnkzNTA0NjgyNA==',
              'name': 'watchbot',
              'viewerHasStarred': false
            },
          ]
              .map((map) =>
                  withTypenames ? {'__typename': 'Repository', ...map} : map)
              .toList(),
        },
      },
    };
  }

  const String addStar = r'''
    mutation AddStar($starrableId: ID!) {
      action: addStar(input: {starrableId: $starrableId}) {
        starrable {
          viewerHasStarred
        }
      }
    }
  ''';

  MockLink link;
  GraphQLClient client;

  group('simple json', () {
    setUp(() {
      link = MockLink();

      client = GraphQLClient(
        cache: getTestCache(),
        link: link,
      );
    });

    group('query', () {
      test('successful response', () async {
        final WatchQueryOptions _options = WatchQueryOptions(
          document: parseString(readRepositories),
          variables: <String, dynamic>{
            'nRepositories': 42,
          },
        );
        final repoData = readRepositoryData(withTypenames: true);

        when(
          link.request(any),
        ).thenAnswer(
          (_) => Stream.fromIterable([
            Response(data: repoData),
          ]),
        );

        final QueryResult r = await client.query(_options);

        verify(
          link.request(
            Request(
              operation: Operation(
                document: parseString(readRepositories),
                //operationName: 'ReadRepositories',
              ),
              variables: <String, dynamic>{
                'nRepositories': 42,
              },
              context: Context(),
            ),
          ),
        );

        expect(r.exception, isNull);
        expect(r.data, equals(repoData));
      });

      test('successful response without normalization', () async {
        final readUnidentifiedRepositories = parseString(r'''
            query ReadRepositories($nRepositories: Int!) {
              viewer {
                repositories(last: $nRepositories) {
                  nodes {
                    name
                    viewerHasStarred
                  }
                }
              }
            }
          ''');
        final repoData = readRepositoryData(
          withTypenames: false,
          withIds: false,
        );

        final WatchQueryOptions _options = WatchQueryOptions(
          document: readUnidentifiedRepositories,
          variables: {'nRepositories': 42},
        );

        when(
          link.request(any),
        ).thenAnswer(
          (_) => Stream.fromIterable([
            Response(data: repoData),
          ]),
        );

        final QueryResult r = await client.query(_options);

        verify(link.request(_options.asRequest));
        expect(r.data, equals(repoData));
      });

      test('malformed server response', () async {
        final WatchQueryOptions _options = WatchQueryOptions(
          document: parseString(readRepositories),
          variables: {'nRepositories': 42},
        );
        final malformedRepoData = {
          'viewer': {
            // maybe the server doesn't validate response structures properly,
            // or a user generates a response on the client, etc
            'repos': readRepositoryData()['viewer']['repositories']
          },
        };

        when(
          link.request(any),
        ).thenAnswer(
          (_) => Stream.fromIterable([
            Response(data: malformedRepoData),
          ]),
        );

        final QueryResult r = await client.query(_options);

        expect(r.data, equals(malformedRepoData),
            reason: 'Malformed data should be passed along with errors');

        throwsA(isA<PartialDataException>().having(
          (e) => e.path,
          'An accurate path to the first missing subfield',
          ['a', 'b', '__typename'],
        ));
      });

      test('failed query because of an exception with null string', () async {
        final e = Exception();

        when(
          link.request(any),
        ).thenAnswer(
          (_) => Stream.fromFuture(Future.error(e)),
        );

        final QueryResult r = await client.query(
          WatchQueryOptions(
            document: parseString(readRepositories),
          ),
        );

        expect(
          r.exception.linkException.originalException,
          e,
        );
      });

      test('failed query because of an exception with empty string', () async {
        final e = Exception('');

        when(
          link.request(any),
        ).thenAnswer(
          (_) => Stream.fromFuture(Future.error(e)),
        );

        final QueryResult r = await client.query(
          WatchQueryOptions(
            document: parseString(readRepositories),
          ),
        );

        expect(
          r.exception.linkException.originalException,
          e,
        );
      });
//    test('failed query because of because of error response', {});
//    test('failed query because of because of invalid response', () {
//      String responseBody =
//          '{\"message\":\"Bad credentials\",\"documentation_url\":\"https://developer.github.com/v4\"}';
//      int responseCode = 401;
//    });
//    test('partially success query with some errors', {});
    });
    group('mutation', () {
      test('query stream notified', () async {
        final initialQueryResponse = Response(
          data: <String, dynamic>{
            'single': {
              'id': '1',
              '__typename': 'Single',
              'name': 'initialQueryName',
            },
          },
        );
        when(
          link.request(any),
        ).thenAnswer(
          (_) => Stream.fromIterable(
            [initialQueryResponse],
          ),
        );

        final ObservableQuery observable = client.watchQuery(
          WatchQueryOptions(
            document: parseString(readSingle),
            eagerlyFetchResults: true,
            variables: {'id': '1'},
          ),
        );

        expect(
          observable.stream,
          emitsInOrder(
            [
              // we have no optimistic result
              isA<QueryResult>().having(
                (result) => result.isLoading,
                'loading result',
                true,
              ),
              isA<QueryResult>().having(
                (result) => result.data['single']['name'],
                'initial query result',
                'initialQueryName',
              ),
              isA<QueryResult>().having(
                (result) => result.data['single']['name'],
                'result caused by mutation',
                'newNameFromMutation',
              )
            ],
          ),
        );

        final mutationResponseWithNewName = Response(
          data: <String, dynamic>{
            'updateSingle': {
              'id': '1',
              '__typename': 'Single',
              'name': 'newNameFromMutation',
            },
          },
        );
        when(
          link.request(any),
        ).thenAnswer(
          (_) => Stream.fromIterable(
            [mutationResponseWithNewName],
          ),
        );

        final variables = {'id': '1', 'name': 'newNameFromMutation'};

        final QueryResult response = await client.mutate(MutationOptions(
            document: parseString(writeSingle), variables: variables));

        expect(response.data['updateSingle']['name'], variables['name']);
      });

      test('successful mutation', () async {
        final MutationOptions _options = MutationOptions(
          document: parseString(addStar),
        );

        when(
          link.request(any),
        ).thenAnswer(
          (_) => Stream.fromIterable(
            [
              Response(
                data: <String, dynamic>{
                  'action': {
                    'starrable': {
                      'viewerHasStarred': true,
                    },
                  },
                },
              ),
            ],
          ),
        );

        final QueryResult response = await client.mutate(_options);

        verify(
          link.request(
            Request(
              operation: Operation(
                document: parseString(addStar),
                //operationName: 'AddStar',
              ),
              variables: <String, dynamic>{},
              context: Context(),
            ),
          ),
        );

        expect(response.exception, isNull);
        expect(response.data, isNotNull);
        final bool viewerHasStarred =
            response.data['action']['starrable']['viewerHasStarred'] as bool;
        expect(viewerHasStarred, true);
      });

      test('successful mutation through watchQuery', () async {
        final _options = MutationOptions(
          document: parseString(addStar),
          variables: {},
        );

        when(
          link.request(any),
        ).thenAnswer(
          (_) => Stream.fromIterable(
            [
              Response(
                data: <String, dynamic>{
                  'action': {
                    'starrable': {
                      'viewerHasStarred': true,
                    },
                  },
                },
              ),
            ],
          ),
        );

        final observableQuery = await client.watchQuery(WatchQueryOptions(
          document: _options.document,
          variables: _options.variables,
          fetchResults: false,
        ));

        final result = await observableQuery.fetchResults().networkResult;

        verify(
          link.request(
            Request(
              operation: Operation(
                document: parseString(addStar),
                //operationName: 'AddStar',
              ),
              variables: <String, dynamic>{},
              context: Context(),
            ),
          ),
        );

        expect(result.hasException, isFalse);
        expect(result.data, isNotNull);
        final bool viewerHasStarred =
            result.data['action']['starrable']['viewerHasStarred'] as bool;
        expect(viewerHasStarred, true);
      });

      /// https://github.com/zino-app/graphql-flutter/issues/747#issuecomment-731649547
      test('watchQuery mutations are isolated', () async {
        //client.writeFragment(
        //  FragmentRequest(
        //    fragment: Fragment(document: gql(order.fragment)),
        //    idFields: {'__typename': 'Order', 'id': order.closedOrder['id']},
        //    variables: {'placeId': (order.closedOrder['place'] as Map)['id']},
        //  ),
        //  data: order.closedOrder,
        //);
        //print(client.cache.store.toMap());

        int count = 0;

        final mutation = gql(order.mutation);
        var _options = MutationOptions(
          document: mutation,
          variables: {
            'placeId': (order.expectedResult['place'] as Map)['id'],
            'lines': [order.closedOrderLineCreate],
            'name': null
          },
        );

        when(
          link.request(any),
        ).thenAnswer(
          (_) => Stream.fromIterable(
            [
              Response(
                data: {
                  'createOrder':
                      count < 1 ? order.closedOrder : order.expectedResult,
                  '__typename': 'Mutation'
                },
              ),
            ],
          ),
        );

        var observableQuery = await client.watchQuery(WatchQueryOptions(
          document: _options.document,
          variables: _options.variables,
          fetchResults: false,
        ));
        var result = await observableQuery.fetchResults().networkResult;
        expect(result.data['createOrder'], equals(order.closedOrder));

        count += 1;

        observableQuery.options.variables = {
          'placeId': (order.expectedResult['place'] as Map)['id'],
          'lines': [order.openOrderLineCreate],
          'name': null
        };

        result = await observableQuery.fetchResults().networkResult;

        //print(jsonEncode(client.cache.store.toMap()));

        expect(result.hasException, isFalse);
        expect(result.data['createOrder'], equals(order.expectedResult));
      });
    });

    group('subscription', () {
      test('results', () async {
        final responses = [
          {
            'id': '1',
            'name': 'first',
          },
          {
            'id': '2',
            'name': 'second',
          },
        ].map((item) => Response(
              data: <String, dynamic>{
                'item': {
                  '__typename': 'Item',
                  ...item,
                },
              },
            ));
        when(
          link.request(any),
        ).thenAnswer(
          (_) => Stream.fromIterable(responses),
        );

        final stream = client.subscribe(
          SubscriptionOptions(
            document: parseString(
              r'''
                subscription {
                  item {
                    id
                    name
                  }
                }
              ''',
            ),
          ),
        );

        expect(
          stream,
          emitsInOrder(
            [
              isA<QueryResult>().having(
                (result) => result.data['item']['name'],
                'first subscription item',
                'first',
              ),
              isA<QueryResult>().having(
                (result) => result.data['item']['name'],
                'second subscription item',
                'second',
              )
            ],
          ),
        );
      });

      test('wraps stream exceptions', () async {
        final ex = ServerException(
          parsedResponse: null,
          originalException: Error(),
        );

        when(
          link.request(any),
        ).thenAnswer(
          (_) => Stream.error(ex),
        );

        final stream = client.subscribe(
          SubscriptionOptions(
            document: parseString(
              r'''
                subscription {
                  item {
                    id
                    name
                  }
                }
              ''',
            ),
          ),
        );

        expect(
          stream,
          emitsInOrder(
            [
              isA<QueryResult>().having(
                (result) => result.exception.linkException,
                'wrapped exception',
                ex,
              ),
            ],
          ),
        );
      });
      test('wraps all exceptions from outside of stream', () async {
        final err = Error();

        when(
          link.request(any),
        ).thenThrow(err);

        final stream = client.subscribe(
          SubscriptionOptions(
            document: parseString(
              r'''
                subscription {
                  item {
                    id
                    name
                  }
                }
              ''',
            ),
          ),
        );

        expect(
          stream,
          emitsInOrder(
            [
              isA<QueryResult>().having(
                (result) => result.exception.linkException.originalException,
                'wrapped exception',
                err,
              ),
            ],
          ),
        );
      });
    });
  });

  group('direct cache access', () {
    setUp(() {
      link = MockLink();

      client = GraphQLClient(
        cache: getTestCache(),
        link: link,
      );
    });

    test('all methods with exposition', () {
      /// entity identifiers for normalization
      final idFields = {'__typename': 'MyType', 'id': 1};

      /// The direct cache API uses `gql_link` Requests directly
      /// These can also be obtained via `options.asRequest` from any `Options` object,
      /// or via `Operation(document: gql(...)).asRequest()`
      final queryRequest = Request(
        operation: Operation(
          document: gql(
            r'''{
              someField {
                id,
                myField
              }
            }''',
          ),
        ),
      );

      final queryData = {
        '__typename': 'Query',
        'someField': {
          ...idFields,
          'myField': 'originalValue',
        },
      };

      /// `broadcast: true` (the default) would rebroadcast cache updates to all safe instances of `ObservableQuery`
      /// **NOTE**: only `GraphQLClient` can immediately call for a query rebroadcast. if you request a rebroadcast directly
      /// from the cache, it still has to wait for the client to check in on it
      client.writeQuery(queryRequest, data: queryData, broadcast: false);

      /// `optimistic: true` (the default) integrates optimistic data
      /// written to the cache into your read.
      expect(
          client.readQuery(queryRequest, optimistic: false), equals(queryData));

      /// While fragments are never executed themselves, we provide a `gql_link`-like API for consistency.
      /// These can also be obtained via `Fragment(document: gql(...)).asRequest()`.
      final fragmentRequest = FragmentRequest(
        fragment: Fragment(
          document: gql(
            r'''
                fragment mySmallSubset on MyType {
                  myField,
                  someNewField
                }
              ''',
          ),
        ),
        idFields: idFields,
      );

      /// We've specified `idFields` and are only editing a subset of the data
      final fragmentData = {
        'myField': 'updatedValue',
        'someNewField': [
          {'newData': false}
        ],
      };

      /// We didn't disable `broadcast`, so all instances of `ObservableQuery` will be notified of any changes
      client.writeFragment(fragmentRequest, data: fragmentData);

      /// __typename is automatically included in all reads
      expect(
        client.readFragment(fragmentRequest),
        equals({
          '__typename': 'MyType',
          ...fragmentData,
        }),
      );

      final updatedQueryData = {
        '__typename': 'Query',
        'someField': {
          ...idFields,
          'myField': 'updatedValue',
        },
      };

      /// `myField` is updated, but we don't have `someNewField`, as expected.
      expect(client.readQuery(queryRequest), equals(updatedQueryData));
    });
  });
}
