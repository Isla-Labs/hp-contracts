// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CvmJob } from "@types/oracle/CvmTypes.sol";

library CvmErrors {
    error ZeroAddress();
    error ZeroDeviceId();
    error ZeroComposeHash();
    error InvalidJob(CvmJob job);
    error InvalidConfig();
    error OnlyOracle(address caller);
    error OnlyAssignee(address assignee, address caller);
    error NoLiveOracle();
    error OnlyRouter(address caller);
    error OnlyRequester(address caller);
    error RequesterNotAllowed(address caller);
    error UnknownRequest(bytes32 requestId);
    error RequestTimedOut(bytes32 requestId);
    error RequestNotTimedOut(bytes32 requestId);
    error DuplicateRequestId(bytes32 requestId);
    error NotOracle(address transmitter);
    error AttestationVerifierNotSet();
    error ComposeNotAllowed(bytes32 composeHash);
    error ZeroRegistrationTtl();
}
