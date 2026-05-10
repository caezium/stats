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

-(bool)insert:(NSString *)key value:(NSString *)value;

-(NSString *)findOne:(NSString *)key;
-(NSString *)findLast:(NSString *)prefix;
-(NSArray *)findMany:(NSString *)prefix;
-(NSDictionary *)findKeysAndValues:(NSString *)prefix;

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

-(void)close;

@end
