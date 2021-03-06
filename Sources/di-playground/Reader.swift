//
//  Reader.swift
//  di-playground
//
//  Created by Brandon Kase on 5/29/17.
//
//

/// What does it mean to depend on something? Isn't a depending on something
/// a function that takes the dependency as input? In the Reader case, all
/// operations in your module become functions that take some dependency `In` as 
/// input.

/// But threading the config through every operation would be too annoying,
/// so we can wrap a function that takes some input `In` and returns some `Data` into
/// a data structure. This structure is called a Reader because we read input from
/// the environment.

/// --- Start reusable library code ---

struct Reader<In, Data> {
    let run: (In) -> Data
    
    /// At any point in time we can ask for the dependency in our program. This is
    /// just a wrapped identity function.
    static var ask: Reader<In, In> {
	   return Reader<In, In> { i in i }
    }
    
    /// We may want to expand our input Reader by saying this
    /// reader is locally part of some larger general one by providing
    /// a reverse transform (since we're transforming the input)
    ///
    /// This is useful to decompose a program that may depend on several dependencies
    /// into one that only depends on a small subset (and define some sort of DSL on
    /// each subset)
    func local<InG>(_ f: @escaping (InG) -> In) -> Reader<InG, Data> {
        return Reader<InG, Data> { i in self.run(f(i)) }
    }
}

extension Reader /* Functor */ {
    /// We can map over a reader by transforming the result of our wrapped
    /// function after we feed it our dependency
    func map<B>(_ f: @escaping (Data) -> B) -> Reader<In, B> {
        return Reader<In, B> { i in f(self.run(i)) }
    }
}

/// Reader is a Monad -- that's why this pattern is called the "Reader Monad"
extension Reader /* Monad */ {
    /// We can turn a piece of data into a reader by wrapping it in a
    /// constant function (a function that ignores it's input and returns some
    /// constant value)
    static func pure(a: Data) -> Reader<In, Data> {
        return Reader<In, Data> { _ in a }
    }
    
    /// Flatmap is similar to our implementation of map, but
    /// instead of getting a value out of our transform function we get another
    /// reader! We can immediately run this inner reader because our input
    /// is in scope.
    func flatMap<B>(_ f: @escaping (Data) -> Reader<In, B>) -> Reader<In, B> {
        return Reader<In, B> { i in f(self.run(i)).run(i) }
    }
}

/// --- End resuable library code ---

/// Abstract Datastore

/// We define services using protocols
protocol ReaderDataStore {
    func get(key: String) -> String
    func set(key: String, value: String)
}

/// We can wrap up our operations in a domain-specific-language or DSL
/// that may use any parts of our config through a Reader (in this case,
/// the datastore).
///
/// Our DSL is just a collection of functions in this case: our dependency is 
/// captured per command, not with any state in a class or struct.
enum ReaderDataStoreDsl {
    /// Get returns a Reader<Config, String> in other words given the dependency 
    /// it will produce a String
    static func get(key: String) -> Reader<ReaderDataStore, String> {
        return Reader<ReaderDataStore, String> { store in store.get(key: key) }
    }
    
    /// Here we are just performing a side-effect when we get the Config, so
    /// our reader returns () or Void when given the dependency
    static func set(key: String, value: String) -> Reader<ReaderDataStore, ()> {
        return Reader<ReaderDataStore, ()> { store in store.set(key: key, value: value) }
    }
}

/// Main Program

/// Config is all dependencies we need to run our program
/// In this case, we just need a ReaderDataStore
struct Config {
    let dataStore: ReaderDataStore
    /* and whatever else we need */
}

/// Our program that uses our DSL is also just a static method, no state needed
enum ReaderProgram {
    /// The actual computation is wrapped up in a reader composed with a series
    /// of maps and flatmaps
    static func main() -> Reader<Config, String> {
        return ReaderDataStoreDsl.set(key: "name", value: "Brandon").flatMap { _ in
            ReaderDataStoreDsl.get(key: "name")
        }.map{ name in "Hello \(name)" }
            /// Now we need to lift the Reader to our config domain
            .local{ config in config.dataStore }
    }
}

/// --- Bonus ---

/// We can create effect stacks using Reader to flatMap/map over more than just the dependency at the same time!
/// For example, we can capture failure as well when we use our cache
enum OptionReaderDataStoreDsl {
    static func get(key: String) -> OptionReader<ReaderDataStore, String> {
        return OptionReader(Reader{ store in store.get(key: key) })
    }
    static func set(key: String, value: String) -> OptionReader<ReaderDataStore, ()> {
        return OptionReader(Reader{ store in store.set(key: key, value: value)})
    }
}

/// OptionReader is an effect stack that captures the effects of failure and dependencies in a single type.
///
/// Really, it just wraps a Reader of an Optional. This is nice, though, because we'll be able to handle several effects with a single flatMap
struct OptionReader<In, Data> {
    let reader: Reader<In, Data?>
    init(_ reader: Reader<In, Data?>) {
        self.reader = reader
    }
}

extension OptionReader /* Functor */ {
    /// We can map over an option reader by delegating to reader's map and optional's map
    func map<B>(_ f: @escaping (Data) -> B) -> OptionReader<In, B> {
        return OptionReader<In, B>(reader.map{ (data: Data?) -> B? in data.map(f) })
    }
}

/// OptionReader is a Monad, because option is a monad, reader is a monad and monads can stack!
extension OptionReader /* Monad */ {
    /// We can turn a piece of data into an option reader by wrapping it in
    /// an option and then a reader
    static func pure(a: Data) -> OptionReader<In, Data> {
        return OptionReader(Reader.pure(a: .some(a)))
    }
    
    /// Flatmap also delegates to reader and option again, but it's a little more work because of all the nested wrappings
    /// It's just using what you have in scope to try and get things to typecheck.
    func flatMap<B>(_ f: @escaping (Data) -> OptionReader<In, B>) -> OptionReader<In, B> {
        return OptionReader<In, B>(
            Reader<In, B?>{ (deps: In) -> B? in
                self.reader.map{ (maybeData: Data?) -> B? in
                    maybeData.flatMap{ (data: Data) -> B? in
                        f(data).reader.run(deps)
                    }
                }.run(deps)
            }
        )
        
    }
}

/// We want to be able to combine operations using only part of our effect stack with ones using other parts easily
/// We can define lifting operations to bring operations that use only one effect into the universe of all of them
extension OptionReader {
    static func lift(reader: Reader<In, Data>) -> OptionReader<In, Data> {
        return OptionReader(reader.map{ .some($0) })
    }
    
    static func lift(optional: Data?) -> OptionReader<In, Data> {
        return OptionReader(Reader.pure(a: optional))
    }
}

/// Now we're free to mix and match mini programs that use different effects
protocol MixAndMatch {
    /// Only uses failure
    func takeFirstName(data: String) -> String?
    /// Only uses dependencies
    func turnOnCache() -> Reader<ReaderDataStore, ()>
    /// Uses all effects (depedendencies + failure)
    func getFromCache(key: String) -> OptionReader<ReaderDataStore, String>
}

/// It's usually nice to define a concise typealias
/// since the lifting distracts from the actual work
typealias O<A> = OptionReader<ReaderDataStore, A>
/// To pretend we have the above functions implemented, I'll
/// define the usage of those functions within a protocol extension
extension MixAndMatch {
    func mixAndMatch(key: String) -> OptionReader<ReaderDataStore, String> {
        return O<()>.lift(reader: turnOnCache()).flatMap{ () in
            O<String>.lift(optional: self.takeFirstName(data: key))
        }.flatMap(getFromCache)
    }
}


