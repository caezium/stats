//
//  lldb.m
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 03/02/2024
//  Using Swift 5.0
//  Running on macOS 14.3
//
//  Copyright © 2024 Serhiy Mytrovtsiy. All rights reserved.
//

#import "lldb.h"

#include <iostream>
#include <sstream>
#include <string>

#import <db.h>
#import <write_batch.h>

using namespace std;

@implementation LLDB {
    leveldb::DB *db;
}

- (instancetype) init:(NSString *) name {
    self = [super init];
    if (self) {
        bool status = [self createDB:name];
        if (!status) {
            return nil;
        }
    }
    return self;
}

-(bool)createDB:(NSString *) path {
    leveldb::Options options;
    options.create_if_missing = true;
    leveldb::Status status = leveldb::DB::Open(options, [path UTF8String], &self->db);
    if (false == status.ok()) {
        NSLog(@"ERROR: Unable to open/create database: %s", status.ToString().c_str());
        return false;
    }
    return true;
}

-(NSArray *)keys:(NSString *)key {
    leveldb::ReadOptions readOptions;
    leveldb::Iterator *it = db->NewIterator(readOptions);
    leveldb::Slice slice = leveldb::Slice(key.UTF8String);
    NSMutableArray *array = [[NSMutableArray alloc] init];
    
    for (it->Seek(slice); it->Valid() && it->key().starts_with(slice); it->Next()) {
        NSString *value = [[NSString alloc] initWithCString:it->key().ToString().c_str() encoding: NSUTF8StringEncoding];
        [array addObject:value];
    }
    delete it;
    
    return array;
}

-(bool)insert:(NSString *)key value:(NSString *)value {
    ostringstream keyStream;
    keyStream << key.UTF8String;
    
    ostringstream valueStream;
    valueStream << value.UTF8String;
    
    leveldb::WriteOptions writeOptions;
    leveldb::Status s = self->db->Put(writeOptions, keyStream.str(), valueStream.str());
    
    return s.ok();
}

-(NSString *)findOne:(NSString *)key {
    ostringstream keyStream;
    keyStream << key.UTF8String;
    
    leveldb::ReadOptions readOptions;
    string value;
    leveldb::Status s = self->db->Get(readOptions, keyStream.str(), &value);
    
    NSString *nsstr = [[NSString alloc] initWithUTF8String:value.c_str()];
    
    return [nsstr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

-(NSString *)findLast:(NSString *)prefix {
    leveldb::ReadOptions readOptions;
    leveldb::Iterator *it = db->NewIterator(readOptions);
    leveldb::Slice slice = leveldb::Slice(prefix.UTF8String);
    NSString *value;
    
    it->SeekToLast();
    
    for (it->SeekToLast(); it->Valid() && it->key().starts_with(slice);) {
        value = [[NSString alloc] initWithCString:it->value().ToString().c_str() encoding:[NSString defaultCStringEncoding]];
        break;
    }
    delete it;
    
    return value;
}

-(NSArray *)findMany:(NSString *)prefix {
    leveldb::ReadOptions readOptions;
    leveldb::Iterator *it = db->NewIterator(readOptions);
    leveldb::Slice slice = leveldb::Slice(prefix.UTF8String);
    NSMutableArray *array = [[NSMutableArray alloc] init];

    for (it->Seek(slice); it->Valid() && it->key().starts_with(slice); it->Next()) {
        NSString *value = [[NSString alloc] initWithCString:it->value().ToString().c_str() encoding:[NSString defaultCStringEncoding]];
        [array addObject:value];
    }
    delete it;

    return array;
}

-(NSDictionary *)findLastKeyAndValue:(NSString *)prefix {
    leveldb::ReadOptions readOptions;
    leveldb::Iterator *it = db->NewIterator(readOptions);
    leveldb::Slice prefixSlice = leveldb::Slice(prefix.UTF8String);

    // Seek to first key strictly greater than any key under `prefix`, then step
    // back. U+FFFF (encoded `EF BF BF`) sorts above any ASCII byte, so any key
    // sharing `prefix` is < `prefix` + U+FFFF. If the seek lands past the end
    // of the database (no such key), SeekToLast still gives us the database's
    // last key, which we'll prefix-check below.
    NSString *upper = [prefix stringByAppendingString:@"￿"];
    leveldb::Slice upperSlice = leveldb::Slice(upper.UTF8String);
    NSDictionary *result = nil;

    it->Seek(upperSlice);
    if (it->Valid()) {
        it->Prev();
    } else {
        it->SeekToLast();
    }

    if (it->Valid() && it->key().starts_with(prefixSlice)) {
        NSString *k = [[NSString alloc] initWithCString:it->key().ToString().c_str() encoding:NSUTF8StringEncoding];
        NSString *v = [[NSString alloc] initWithCString:it->value().ToString().c_str() encoding:NSUTF8StringEncoding];
        if (k != nil && v != nil) {
            result = @{k: v};
        }
    }
    delete it;
    return result;
}

-(NSArray *)sampleByStride:(NSString *)prefix from:(int64_t)lo to:(int64_t)hi strideSec:(int)strideSec {
    if (strideSec <= 0) { strideSec = 1; }
    leveldb::ReadOptions readOptions;
    leveldb::Iterator *it = db->NewIterator(readOptions);
    NSMutableArray *out = [[NSMutableArray alloc] init];

    NSString *prefixWithAt = [prefix hasSuffix:@"@"] ? prefix : [prefix stringByAppendingString:@"@"];
    NSUInteger pfxLen = [prefixWithAt lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    leveldb::Slice prefixSlice = leveldb::Slice([prefixWithAt UTF8String], pfxLen);

    int64_t target = lo;
    int64_t lastTS = -1;

    while (target <= hi) {
        // The seek key only needs to live until Seek() returns; constructing it
        // each iteration keeps the autorelease pool in check across long sweeps.
        NSString *seekKey = [NSString stringWithFormat:@"%@%lld", prefixWithAt, target];
        leveldb::Slice slice = leveldb::Slice(seekKey.UTF8String);
        it->Seek(slice);
        if (!it->Valid() || !it->key().starts_with(prefixSlice)) { break; }

        std::string ks = it->key().ToString();
        const char *tail = ks.c_str() + pfxLen;

        // Validate the tail is a pure decimal in our 10-digit unix-seconds
        // range. A row with a malformed ts (atoll returning 0, or any value
        // outside [lo, hi]) would otherwise be emitted with ts=0 → the chart
        // domain stretches from 1970 to today and every x-axis label
        // collapses to "00:00". Skip those rows and continue sampling.
        if (tail[0] < '0' || tail[0] > '9') {
            target += strideSec;
            continue;
        }
        int64_t ts = atoll(tail);
        if (ts < lo) {
            // Seek landed below the requested window — possible if a row's
            // key starts with our prefix but its ts isn't a real timestamp.
            // Advance past it.
            target = lo > ts + strideSec ? lo : ts + strideSec;
            continue;
        }
        if (ts > hi) { break; }
        if (ts == lastTS) {
            // Defensive: if we somehow landed on the same row twice (sparse data
            // far enough apart that target+stride still seeks to the same key),
            // step our virtual cursor past it so we make progress.
            target = ts + strideSec;
            continue;
        }

        NSString *jsonStr = [[NSString alloc] initWithCString:it->value().ToString().c_str() encoding:NSUTF8StringEncoding];
        if (jsonStr != nil) {
            [out addObject:@[@(ts), jsonStr]];
        }
        lastTS = ts;
        // Advance from the row we actually got, not from the seek target — sparse
        // regions otherwise loop revisiting the same key without progress.
        target = ts + strideSec;
    }
    delete it;
    return out;
}

-(NSDictionary *)findKeysAndValues:(NSString *)prefix {
    leveldb::ReadOptions readOptions;
    leveldb::Iterator *it = db->NewIterator(readOptions);
    leveldb::Slice slice = leveldb::Slice(prefix.UTF8String);
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];

    for (it->Seek(slice); it->Valid() && it->key().starts_with(slice); it->Next()) {
        NSString *k = [[NSString alloc] initWithCString:it->key().ToString().c_str() encoding:NSUTF8StringEncoding];
        NSString *v = [[NSString alloc] initWithCString:it->value().ToString().c_str() encoding:NSUTF8StringEncoding];
        if (k != nil && v != nil) {
            dict[k] = v;
        }
    }
    delete it;

    return dict;
}

-(NSArray *)keysInRange:(NSString *)startKey end:(NSString *)endKey {
    leveldb::ReadOptions readOptions;
    leveldb::Iterator *it = db->NewIterator(readOptions);
    leveldb::Slice startSlice = leveldb::Slice(startKey.UTF8String);
    std::string endStr = std::string(endKey.UTF8String);
    NSMutableArray *array = [[NSMutableArray alloc] init];

    for (it->Seek(startSlice); it->Valid() && it->key().ToString() < endStr; it->Next()) {
        NSString *k = [[NSString alloc] initWithCString:it->key().ToString().c_str() encoding:NSUTF8StringEncoding];
        if (k != nil) {
            [array addObject:k];
        }
    }
    delete it;

    return array;
}

-(NSDictionary *)findKeysAndValuesInRange:(NSString *)startKey end:(NSString *)endKey {
    leveldb::ReadOptions readOptions;
    leveldb::Iterator *it = db->NewIterator(readOptions);
    leveldb::Slice startSlice = leveldb::Slice(startKey.UTF8String);
    std::string endStr = std::string(endKey.UTF8String);
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];

    for (it->Seek(startSlice); it->Valid() && it->key().ToString() < endStr; it->Next()) {
        NSString *k = [[NSString alloc] initWithCString:it->key().ToString().c_str() encoding:NSUTF8StringEncoding];
        NSString *v = [[NSString alloc] initWithCString:it->value().ToString().c_str() encoding:NSUTF8StringEncoding];
        if (k != nil && v != nil) {
            dict[k] = v;
        }
    }
    delete it;

    return dict;
}

-(bool)deleteOne:(NSString *)key {
    ostringstream keySream;
    keySream << key.UTF8String;
    
    leveldb::WriteOptions writeOptions;
    leveldb::Status s = self->db->Delete(writeOptions, keySream.str());
    
    return s.ok();
}

-(bool)deleteMany:(NSArray*)keys {
    leveldb::WriteBatch batch;

    for (int i=0; i <[keys count]; i++) {
        NSString *key = [keys objectAtIndex:i];
        leveldb::Slice slice = leveldb::Slice(key.UTF8String);
        batch.Delete(slice);
    }

    leveldb::Status s = self->db->Write(leveldb::WriteOptions(), &batch);
    return s.ok();
}

-(bool)compactRollup:(NSString *)targetKey value:(NSString *)targetValue removing:(NSArray *)oldKeys {
    leveldb::WriteBatch batch;

    batch.Put(leveldb::Slice(targetKey.UTF8String), leveldb::Slice(targetValue.UTF8String));

    for (int i=0; i < [oldKeys count]; i++) {
        NSString *k = [oldKeys objectAtIndex:i];
        // Skip the target key if it appears in the deletion list — within a single
        // WriteBatch the Delete would land after the Put and erase the merged value.
        if ([k isEqualToString:targetKey]) { continue; }
        batch.Delete(leveldb::Slice(k.UTF8String));
    }

    leveldb::Status s = self->db->Write(leveldb::WriteOptions(), &batch);
    return s.ok();
}

-(void)compactRange {
    // Passing nullptr/nullptr for begin/end compacts the entire keyspace.
    db->CompactRange(NULL, NULL);
}

-(void)close {
    delete self->db;
}

@end
