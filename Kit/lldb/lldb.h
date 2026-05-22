//
//  lldb.h
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 03/02/2024
//  Using Swift 5.0
//  Running on macOS 14.3
//
//  Copyright © 2024 Serhiy Mytrovtsiy. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface LLDB:NSObject
-(instancetype)init:(NSString *) path;

-(NSArray *)keys:(NSString *)key;

// Range-bounded keys-only iteration. Returns every key in [startKey, endKey)
// regardless of common prefix. Use when you need just keys (not values) over
// a bounded window — e.g. tier compaction picks the keys that have aged past
// 30 days without pulling values for the rest of the prefix.
-(NSArray *)keysInRange:(NSString *)startKey end:(NSString *)endKey;

-(bool)insert:(NSString *)key value:(NSString *)value;

-(NSString *)findOne:(NSString *)key;
-(NSString *)findLast:(NSString *)prefix;
-(NSArray *)findMany:(NSString *)prefix;
-(NSDictionary *)findKeysAndValues:(NSString *)prefix;

// Returns a single-entry NSDictionary mapping the lex-greatest key under `prefix`
// to its value. O(log N) via a reverse iterator — does not materialize the prefix.
// Use when the caller actually wants the most recent timestamped row for a
// `<module>@<reader>` prefix; the existing `findLast:` returns only the value
// and is broken for any prefix that doesn't happen to sort last in the database.
-(NSDictionary *)findLastKeyAndValue:(NSString *)prefix;

// Streaming stride sampler. Walks the keyspace under `prefix@<ts>` from `lo`
// to `hi` (inclusive), seeking to `lo`, `landed_ts + strideSec`, ... until
// the iterator leaves the prefix or passes `hi`. Returns an NSArray of
// `@[@(ts), jsonString]` pairs — at most ~((hi-lo)/strideSec)+1 entries.
//
// Cost is O(maxPoints * log N) leveldb seeks rather than O(N) full scan, and
// memory is bounded to the returned slice. Use for chart-series queries on
// high-cardinality prefixes (Network@UsageReader, Network@ProcessReader)
// where a 7-day window contains ~600k rows but the chart only needs a few
// hundred plotted points.
-(NSArray *)sampleByStride:(NSString *)prefix from:(int64_t)lo to:(int64_t)hi strideSec:(int)strideSec;

// Range-bounded variant of findKeysAndValues. Iterates from `startKey` (inclusive)
// up to but not including `endKey`, regardless of common prefix. Used by the time-
// series read path so queries like "last hour" don't have to scan every history row
// for a module just to filter by timestamp afterwards.
-(NSDictionary *)findKeysAndValuesInRange:(NSString *)startKey end:(NSString *)endKey;

-(bool)deleteOne:(NSString *)key;
-(bool)deleteMany:(NSArray*)keys;

// Atomic rollup primitive used by tier compaction. Writes `targetKey` -> `targetValue`
// and deletes every key in `oldKeys` in a single WriteBatch, so a crash mid-rollup
// can never leave the store with both the merged target AND its source rows.
-(bool)compactRollup:(NSString *)targetKey value:(NSString *)targetValue removing:(NSArray *)oldKeys;

// Full-keyspace compaction: tells leveldb to merge SSTables and drop
// tombstones across the entire DB. Reclaims the bloat that accumulates from
// `compactRollup` deletes and from repeated overwrites at the bare-key
// latest-value mirrors. Synchronous from this thread's perspective but
// leveldb does not block concurrent reads/writes from other threads.
//
// Called hourly from `DB.runMaintenanceCycleOnQueue`. Without it the on-disk
// store grows to ~10× the working set before leveldb's own background
// compaction catches up.
-(void)compactRange;

-(void)close;

@end
