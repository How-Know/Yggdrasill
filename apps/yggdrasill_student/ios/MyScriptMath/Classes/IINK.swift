// Copyright @ MyScript. All rights reserved.
// (iink 헤더는 같은 pod 모듈에 포함되므로 별도 import 가 필요 없다)

//
// Refinements of the MyScript Interactive Ink Runtime API for Swift
//

extension IINKParameterSet {
    func boolean(for key: String) throws -> Bool {
        let v = try boolean(forKey: key)
        return v.value;
    }
    func number(for key: String) throws -> Double {
        let v = try number(forKey: key)
        return v.value;
    }
}
