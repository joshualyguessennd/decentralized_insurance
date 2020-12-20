pragma solidity ^0.4.24;

import "@chainlink/src/v0.4/ChainlinkClient.sol";
import "@chainlink/src/v0.4/vendor/Ownable.sol";
import "@chainlink/src/v0.4/interfaces/LinkTokenInterface.sol";

contract InsuranceProvider{
    mapping (address => InsuranceContract ) contracts;
    constructor() public payable {
        priceFeed = AggregatorV3Interface(0x9326BFA02ADD2366b30bacB125260Af641031331);
    }

    function newContract(address _client, uint _duration, uint _premium, uint _payoutValue, string _cropLocation) public payable onlyOwner() returns(address) {
        //create contract, send payout amount to fund the contract
        insuranceContract i = (new InsuranceContract).value((_payoutValue * 1 ether).div(uint(getLatestPrice())))(_client, _duration, _premium, _payoutValue, _cropLocation, LINK_KOVAN, ORACLE_PAYMENT);
        //store the new contract into the map
        contracts[address(i)] = i;
        // emit an event to say contract has been created and funded
        emit contractCreated(address(i), msg.value, _payoutValue);

        //fund the contract with link to fulfill 1 oracle request per day
        LinkTokenInterface link = LinkTokenInterface(i.getChainLinkToken());
        link.transfer(address(i), ((_duration.div(DAY_IN_SECONDS)) + 2) * ORACLE_PAYMENT.mul(2));

        return address(i);
    }

    function updateContract(address _contract) external {
        InsuranceContract i = InsuranceContract(_contract);
        i.updateContract();
    }

    function getContractRainfall(address _contract) external returns(uint) {
        InsuranceContract i  = InsuranceContract(_contract);
        return i.getCurrentRainfall();
    }

    function getContractRequestCount(address _contract) external view returns(uint) {
        InsuranceContract i = InsuranceContract(_contract);
        return i.getRequestCount();
    }
}

contract InsuranceContract is ChainlinkClient, Ownable {
    string constant WORLD_WEATHER_ONLINE_URL = "http://api.worldweatheronline.com/premium/v1/weather.ashx?";
    string constant WORLD_WEATHER_ONLINE_KEY = "insert API key here";
    string constant WORLD_WEATHER_ONLINE_PATH = "data.current_condition.0.precipMM";
      
    string constant WEATHERBIT_URL = "https://api.weatherbit.io/v2.0/current?";
    string constant WEATHERBIT_KEY = "insert API key here";
    string constant WEATHERBIT_PATH = "data.0.precip";

    constructor(address _client, uint _duration, uint _premium, uint _payoutValue, string _cropLocation, address _link, uint256 _oraclePaymentAmount) payable Ownable() public {
        priceFeed = AggregatorV3Interface(0x9326BFA02ADD2366b30bacB125260Af641031331);
        setChainlinkToken(_link);
        oraclePayAmount = _oraclePaymentAmount;

        require(msg.value >= _payoutValue.div(uint(getLatestPrice())), "not enough fund in the contract");

        insurer = msg.sender;
        client = _client;
        startDate = now + DAY_IN_SECONDS; // the contract start the next day
        duration = _duration;
        premium = _premium;
        payoutValue = _payoutValue;
        daysWithoutRain = 0;
        contractActive = true;
        cropLocation = _cropLocation;

        //if you have your own node and job setup you can use both requests
        oracles[0] = 0x05c8fadf1798437c143683e665800d58a42b6e19;
        oracles[1] = 0x05c8fadf1798437c143683e665800d58a42b6e19;
        jobIds[0] = 'a17e8fbf4cbf46eeb79e04b3eb864a4e';
        jobIds[1] = 'a17e8fbf4cbf46eeb79e04b3eb864a4e';

        emit contractCreated(
            insurer,
            client,
            duration,
            payoutValue
        );


        
    }

    function updateContract() public onContractActive() returns (bytes32 requestId) {
        checkEndContract();

        if (contractActive) {
            dataRequest = 0;
                //First build up a request to World Weather Online to get the current rainfall
            string memory url = string(abi.encodedPacked(WORLD_WEATHER_ONLINE_URL, "key=", WORLD_WEATHER_ONLINE_KEY,"&q=",cropLocation,"&format=json&num_of_days=1"));
            checkRainfall(oracles[0], jobIds[0], url, WORLD_WEATHER_ONLINE_PATH);


                // Now build up the second request to WeatherBit
            url = string(abi.encodePacked(WEATHERBIT_URL, "city=",cropLocation,"&key=",WEATHERBIT_KEY));
            checkRainfall(oracles[1], jobIds[1], url, WEATHERBIT_PATH);
        }
    }


    function checkRainfall(address _oracle, bytes32 _jobId, string _url, string _path) private onContractActive() returns (bytes32 requestId)   {

        //First build up a request to get the current rainfall
        Chainlink.Request memory req = buildChainlinkRequest(_jobId, address(this), this.checkRainfallCallBack.selector);
           
        req.add("get", _url); //sends the GET request to the oracle
        req.add("path", _path);
        req.addInt("times", 100);
        
        requestId = sendChainlinkRequestTo(_oracle, req, oraclePaymentAmount); 
            
        emit dataRequestSent(requestId);
    }

    
    function checkRainfallCallBack(bytes32 _requestId, uint256 _rainfall) public recordChainLinkFulfillment(_requestId) onContractActive() callFrequencyOnePerDay() {
        currentRainfallList[dataRequestsSent] = _rainfall;
        dataRequestsSent = dataRequestsSent + 1;

        if (dataRequestsSent > 1) {
            currentRainfall = (currentRainfallList[0].add(currentRainfallList[1]).div(2));
            currentRainfallDateChecked = now;
            requestCount += 1;

            if(currentRainfall == 0) {
                daysWithoutRain += 1;
            } else {
                daysWithoutRain = 0;
                emit ranfallThresoldReset(currentRainfall);
            }
        }

        if (daysWithoutRain >= DROUGHT_DAYS_THRESOLD) {
            payoutContract();
        }

        emit dataReceived(_rainfall);
    }


    function payOutContract() private onContractActive() {
        client.transfer(address(this).balance);

        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(link.transfer(insurer, link.balanceOf(address(this))), "unable");

        emit contractPaidOut(now, payoutValue, currentRainfall);

        contractActive = false;
        contractPaid = true;
    }


    function checkEndContract() private onContractEnded()   {
        //Insurer needs to have performed at least 1 weather call per day to be eligible to retrieve funds back.
        //We will allow for 1 missed weather call to account for unexpected issues on a given day.
        if (requestCount >= (duration.div(DAY_IN_SECONDS) - 1)) {
            //return funds back to insurance provider then end/kill the contract
            insurer.transfer(address(this).balance);
        } else { //insurer hasn't done the minimum number of data requests, client is eligible to receive his premium back
            client.transfer(premium.div(uint(getLatestPrice())));
            insurer.transfer(address(this).balance);
        }
        
        //transfer any remaining LINK tokens back to the insurer
        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(link.transfer(insurer, link.balanceOf(address(this))), "Unable to transfer remaining LINK tokens");
        
        //mark contract as ended, so no future state changes can occur on the contract
        contractActive = false;
        emit contractEnded(now, address(this).balance);
    }

    
}