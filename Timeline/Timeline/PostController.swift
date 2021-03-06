//
//  PostController.swift
//  Timeline
//
//  Created by Eva Marie Bresciano on 6/13/16.
//  Copyright © 2016 Eva Bresciano. All rights reserved.
//

import Foundation
import UIKit
import CoreData
import CloudKit


class PostController {
    
    var isSyncing: Bool = false
    
    let cloudKitManager: CloudKitManager
    
    static let sharedController = PostController()
    
    func saveContext() {
        do {
            try Stack.sharedStack.managedObjectContext.save()
        } catch {
            print("Could not save")
        }
    }
    
    var posts: [Post] {
        
        let fetchRequest = NSFetchRequest(entityName: Post.kType)
        let sortDescriptor = NSSortDescriptor(key: Post.kTimestamp, ascending: false)
        fetchRequest.sortDescriptors = [sortDescriptor]
        
        let results = (try? Stack.sharedStack.managedObjectContext.executeFetchRequest(fetchRequest)) as? [Post] ?? []
        
        return results
    }
    
    init() {
        
        self.cloudKitManager = CloudKitManager()
        
        performFullSync()
        
        subscribeToNewPosts { (success, error) in
            
            if success {
                print("Successfully subscribed to new posts.")
            }
        }
    }
    
    func createPost(image: UIImage, caption: String, completion: (() -> Void)?) {
        guard let data = UIImageJPEGRepresentation(image, 0.8) else {
            return
        }
        
        let post = Post(photo: data)
        addCommentToPost(caption, post: post, completion: nil)
        saveContext()
        
        if let cloudKitRecord = post.cloudKitRecord {
            cloudKitManager.saveRecord(cloudKitRecord) { (record, error) in
                if let error = error {
                    print("error saving cloudKit record for post \(post): \(error)")
                }
                
                guard let record = record else {
                    return
                }
                
                post.update(record)
            }
        }
    }
    
    func addCommentToPost(text: String, post: Post, completion: ((success: Bool) -> Void)?) {
        let comment = Comment(post: post, text: text)
        saveContext()
        
        if let cloudKitRecord = comment.cloudKitRecord {
            cloudKitManager.saveRecord(cloudKitRecord) { (record, error) in
                if let error = error {
                    print("error saving cloudKit record for comment \(comment): \(error)")
                }
                
                guard let record = record else {
                    return
                }
                comment.update(record)
            }
        }
    }
    
    // MARK: - Helper Functions
    
    func postWithName(name: String) -> Post? {
        if name.isEmpty {
            return nil
        }
        
        let fetchRequest = NSFetchRequest(entityName: Post.kType)
        let predicate = NSPredicate(format: "recordName == %@", argumentArray: [name])
        fetchRequest.predicate = predicate
        
        let result = (try? Stack.sharedStack.managedObjectContext.executeFetchRequest(fetchRequest)) as? [Post] ?? nil
        
        return result?.first
    }
    
    func syncedRecords(type: String) -> [CloudKitManagedObject] {
        let fetchRequest = NSFetchRequest(entityName: type)
        fetchRequest.predicate = NSPredicate(format: "recordIDData != nil")
        
        let moc = Stack.sharedStack.managedObjectContext
        let results = (try? moc.executeFetchRequest(fetchRequest)) as? [CloudKitManagedObject] ?? []
        return results
    }
    
    func unsyncedRecords(type: String) -> [CloudKitManagedObject] {
        let fetchRequest = NSFetchRequest(entityName: type)
        fetchRequest.predicate = NSPredicate(format: "recordIDData != nil")
        
        let moc = Stack.sharedStack.managedObjectContext
        let results = (try? moc.executeFetchRequest(fetchRequest)) as? [CloudKitManagedObject] ?? []
        return results
    }
    
    func fetchNewRecords(type: String, completion: (() -> Void)?) {
        let referencesToExclude = syncedRecords(type).flatMap {$0.cloudKitReference}
        let predicate: NSPredicate
        if !referencesToExclude.isEmpty {
            predicate = NSPredicate(format: "NOT(recordID IN %@)", referencesToExclude)
        } else {
            predicate = NSPredicate(value: true)
            
        }
        
        cloudKitManager.fetchRecordsWithType(type, predicate: predicate, recordFetchedBlock: { (record) in
            switch type {
            case Post.kType:
                let _ = Post(record: record)
            case Comment.kType:
                let _ = Comment(record: record)
            default: return
                
            }
            self.saveContext()
        }) { (records, error) in
            if let error = error {
                print("Error fetching new records from CloudKit: \(error)")
            }
            
            completion?()
        }
    }
    
    func pushChangesToCloudKit(completion: ((success: Bool, error: NSError?) -> Void)? = nil) {
        let unsavedManagedObjects = unsyncedRecords(Post.kType) + unsyncedRecords(Comment.kType)
        let unsavedRecords = unsavedManagedObjects.flatMap { $0.cloudKitRecord }
        
        cloudKitManager.saveRecords(unsavedRecords, perRecordCompletion: { (record, error) in
            guard let record = record else { return }
            if let matchingManagedObject = unsavedManagedObjects.filter({$0.recordName == record.recordID.recordName}).first {
                matchingManagedObject.update(record)
            }
            
        }) { (records, error) in
            let success = records != nil
            completion?(success: success, error: error)
            
        }
    }
    
    func performFullSync(completion: (() -> Void)? = nil) {
        if isSyncing {
            if let completion = completion {
                completion()
            }
            
        } else {
            isSyncing = true
            pushChangesToCloudKit { (success) in
                self.fetchNewRecords(Post.kType) {
                    self.fetchNewRecords(Comment.kType, completion: {
                        
                        self.isSyncing = false
                        if let completion = completion {
                            completion()
                            
                        }
                    })
                }
            }
        }
    }
    
    func subscribeToNewPosts(completion: ((success: Bool, error: NSError?) -> Void)?) {
        
        let predicate = NSPredicate(value: true)
        
        cloudKitManager.subscribe(Post.kType, predicate: predicate, subscriptionID: "allPosts", contentAvailable: true, options: .FiresOnRecordCreation) { (subscription, error) in
            
            if let completion = completion {
                
                let success = subscription != nil
                completion(success: success, error: error)
            }
        }
    }
    
    func checkSubscriptionToPostComments(post: Post, completion: ((subscribed: Bool) -> Void)?) {
        
        cloudKitManager.fetchSubscription(post.recordName) { (subscription, error) in
            
            if let completion = completion {
                
                let subscribed = subscription != nil
                completion(subscribed: subscribed)
            }
        }
    }
    
    func addSubscriptionToPostComments(post: Post, alertBody: String?, completion: ((success: Bool, error: NSError?) -> Void)?) {
        
        guard let recordID = post.cloudKitRecordID else { fatalError("Unable to create CloudKit reference for subscription.") }
        
        let predicate = NSPredicate(format: "post == %@", argumentArray: [recordID])
        
        cloudKitManager.subscribe(Comment.kType, predicate: predicate, subscriptionID: post.recordName, contentAvailable: true, alertBody: alertBody, desiredKeys: [Comment.kText, Comment.kPost], options: .FiresOnRecordCreation) { (subscription, error) in
            
            if let completion = completion {
                
                let success = subscription != nil
                completion(success: success, error: error)
            }
        }
    }
    
    func removeSubscriptionToPostComments(post: Post, completion: ((success: Bool, error: NSError?) -> Void)?) {
        
        let subscriptionID = post.recordName
        
        cloudKitManager.unsubscribe(subscriptionID) { (subscriptionID, error) in
            
            if let completion = completion {
                
                let success = subscriptionID != nil && error == nil
                completion(success: success, error: error)
            }
        }
    }
    
    func togglePostCommentSubscription(post: Post, completion: ((success: Bool, isSubscribed: Bool, error: NSError?) -> Void)?) {
        
        cloudKitManager.fetchSubscriptions { (subscriptions, error) in
            
            if subscriptions?.filter({ $0.subscriptionID == post.recordName }).first != nil {
                
                self.removeSubscriptionToPostComments(post, completion: { (success, error) in
                    
                    if let completion = completion {
                        completion(success: success, isSubscribed: false, error: error)
                    }
                })
            } else {
                
                self.addSubscriptionToPostComments(post, alertBody: "Someone commented on post you follow", completion: { (success, error) in
                    
                    if let completion = completion {
                        completion(success: true, isSubscribed: true, error: error)
                    }
                })
            }
        }
    }
    
    
    
   
    
    
}