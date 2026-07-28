/*
 * MarketScanner read-only relative SE(2) factor-graph helper.
 *
 * The helper deliberately uses RTAB-Map's DBDriver, Link and Optimizer APIs so
 * Link transform conventions and planar information projection are identical
 * to the native graph implementation. It never writes the selected database.
 */

#include <rtabmap/core/DBDriver.h>
#include <rtabmap/core/Link.h>
#include <rtabmap/core/Optimizer.h>
#include <rtabmap/core/Parameters.h>
#include <rtabmap/core/Transform.h>
#include <rtabmap/core/Version.h>
#include <rtabmap/utilite/ULogger.h>

#include <opencv2/core/core.hpp>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <memory>
#include <queue>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <tuple>
#include <vector>

using namespace rtabmap;

namespace {

const char * kFormat = "MarketScannerRelativeSE2FactorGraphReport";
const int kVersion = 1;

struct Sha256
{
	Sha256() : bitLength(0), bufferLength(0)
	{
		const uint32_t initial[8] = {
			0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
			0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U};
		std::copy(initial, initial + 8, state.begin());
	}

	void update(const std::string & input)
	{
		for(size_t i = 0; i < input.size(); ++i)
		{
			buffer[bufferLength++] = static_cast<uint8_t>(input[i]);
			if(bufferLength == 64)
			{
				transform();
				bitLength += 512;
				bufferLength = 0;
			}
		}
	}

	std::string finish()
	{
		uint64_t totalBits = bitLength + static_cast<uint64_t>(bufferLength) * 8U;
		buffer[bufferLength++] = 0x80U;
		if(bufferLength > 56)
		{
			while(bufferLength < 64) buffer[bufferLength++] = 0;
			transform();
			bufferLength = 0;
		}
		while(bufferLength < 56) buffer[bufferLength++] = 0;
		for(int shift = 56; shift >= 0; shift -= 8)
		{
			buffer[bufferLength++] = static_cast<uint8_t>((totalBits >> shift) & 0xffU);
		}
		transform();
		std::ostringstream stream;
		stream << std::hex << std::setfill('0');
		for(size_t i = 0; i < state.size(); ++i) stream << std::setw(8) << state[i];
		return stream.str();
	}

	static uint32_t rotateRight(uint32_t value, uint32_t amount)
	{
		return (value >> amount) | (value << (32U - amount));
	}

	void transform()
	{
		static const uint32_t constants[64] = {
			0x428a2f98U,0x71374491U,0xb5c0fbcfU,0xe9b5dba5U,0x3956c25bU,0x59f111f1U,0x923f82a4U,0xab1c5ed5U,
			0xd807aa98U,0x12835b01U,0x243185beU,0x550c7dc3U,0x72be5d74U,0x80deb1feU,0x9bdc06a7U,0xc19bf174U,
			0xe49b69c1U,0xefbe4786U,0x0fc19dc6U,0x240ca1ccU,0x2de92c6fU,0x4a7484aaU,0x5cb0a9dcU,0x76f988daU,
			0x983e5152U,0xa831c66dU,0xb00327c8U,0xbf597fc7U,0xc6e00bf3U,0xd5a79147U,0x06ca6351U,0x14292967U,
			0x27b70a85U,0x2e1b2138U,0x4d2c6dfcU,0x53380d13U,0x650a7354U,0x766a0abbU,0x81c2c92eU,0x92722c85U,
			0xa2bfe8a1U,0xa81a664bU,0xc24b8b70U,0xc76c51a3U,0xd192e819U,0xd6990624U,0xf40e3585U,0x106aa070U,
			0x19a4c116U,0x1e376c08U,0x2748774cU,0x34b0bcb5U,0x391c0cb3U,0x4ed8aa4aU,0x5b9cca4fU,0x682e6ff3U,
			0x748f82eeU,0x78a5636fU,0x84c87814U,0x8cc70208U,0x90befffaU,0xa4506cebU,0xbef9a3f7U,0xc67178f2U};
		uint32_t words[64];
		for(int i = 0; i < 16; ++i)
		{
			words[i] = (static_cast<uint32_t>(buffer[i*4]) << 24) |
				(static_cast<uint32_t>(buffer[i*4+1]) << 16) |
				(static_cast<uint32_t>(buffer[i*4+2]) << 8) |
				static_cast<uint32_t>(buffer[i*4+3]);
		}
		for(int i = 16; i < 64; ++i)
		{
			uint32_t s0 = rotateRight(words[i-15], 7) ^ rotateRight(words[i-15], 18) ^ (words[i-15] >> 3);
			uint32_t s1 = rotateRight(words[i-2], 17) ^ rotateRight(words[i-2], 19) ^ (words[i-2] >> 10);
			words[i] = words[i-16] + s0 + words[i-7] + s1;
		}
		uint32_t a=state[0], b=state[1], c=state[2], d=state[3];
		uint32_t e=state[4], f=state[5], g=state[6], h=state[7];
		for(int i = 0; i < 64; ++i)
		{
			uint32_t s1 = rotateRight(e,6) ^ rotateRight(e,11) ^ rotateRight(e,25);
			uint32_t choose = (e & f) ^ ((~e) & g);
			uint32_t temp1 = h + s1 + choose + constants[i] + words[i];
			uint32_t s0 = rotateRight(a,2) ^ rotateRight(a,13) ^ rotateRight(a,22);
			uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
			uint32_t temp2 = s0 + majority;
			h=g; g=f; f=e; e=d+temp1; d=c; c=b; b=a; a=temp1+temp2;
		}
		state[0]+=a; state[1]+=b; state[2]+=c; state[3]+=d;
		state[4]+=e; state[5]+=f; state[6]+=g; state[7]+=h;
	}

	std::array<uint32_t, 8> state;
	std::array<uint8_t, 64> buffer;
	uint64_t bitLength;
	size_t bufferLength;
};

struct Options
{
	std::string database;
	std::string output;
	std::string priors;
	std::string inputIdentity;
	std::string databaseSha256;
	std::string horizontalAxes = "xz";
	double initialX = 0.0;
	double initialY = 0.0;
	double initialYaw = 0.0;
	int iterations = 100;
	double epsilon = 1.0e-6;
};

struct Factor
{
	std::string id;
	std::string kind;
	Link link;
	std::array<double, 9> planarInformation;
	std::string canonical;
};

struct Prior
{
	std::string id;
	std::string kind;
	int nodeId;
	double x;
	double y;
	double yaw;
	double weight;
};

double normalizeAngle(double angle)
{
	while(angle > M_PI) angle -= 2.0 * M_PI;
	while(angle <= -M_PI) angle += 2.0 * M_PI;
	return angle;
}

bool finiteTransform(const Transform & transform)
{
	if(transform.isNull() || !transform.isInvertible()) return false;
	for(int i = 0; i < transform.size(); ++i)
	{
		if(!std::isfinite(static_cast<double>(transform[i]))) return false;
	}
	return true;
}

std::string jsonEscape(const std::string & value)
{
	std::ostringstream out;
	for(size_t i = 0; i < value.size(); ++i)
	{
		unsigned char c = static_cast<unsigned char>(value[i]);
		switch(c)
		{
		case '\\': out << "\\\\"; break;
		case '"': out << "\\\""; break;
		case '\b': out << "\\b"; break;
		case '\f': out << "\\f"; break;
		case '\n': out << "\\n"; break;
		case '\r': out << "\\r"; break;
		case '\t': out << "\\t"; break;
		default:
			if(c < 0x20) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c) << std::dec;
			else out << static_cast<char>(c);
		}
	}
	return out.str();
}

std::vector<std::string> splitTabs(const std::string & line)
{
	std::vector<std::string> fields;
	std::string field;
	std::istringstream stream(line);
	while(std::getline(stream, field, '\t')) fields.push_back(field);
	if(!line.empty() && line[line.size()-1] == '\t') fields.push_back("");
	return fields;
}

double parseFinite(const std::string & value, const std::string & field)
{
	char * end = 0;
	errno = 0;
	double parsed = std::strtod(value.c_str(), &end);
	if(errno != 0 || end == value.c_str() || *end != '\0' || !std::isfinite(parsed))
	{
		throw std::runtime_error("Invalid finite " + field + ".");
	}
	return parsed;
}

int parseInteger(const std::string & value, const std::string & field)
{
	char * end = 0;
	errno = 0;
	long parsed = std::strtol(value.c_str(), &end, 10);
	if(errno != 0 || end == value.c_str() || *end != '\0' || parsed <= 0 || parsed > std::numeric_limits<int>::max())
	{
		throw std::runtime_error("Invalid positive " + field + ".");
	}
	return static_cast<int>(parsed);
}

bool isLowerHexSha256(const std::string & value)
{
	if(value.size() != 64) return false;
	for(size_t i = 0; i < value.size(); ++i)
	{
		if(!((value[i] >= '0' && value[i] <= '9') ||
			(value[i] >= 'a' && value[i] <= 'f'))) return false;
	}
	return true;
}

Options parseOptions(int argc, char ** argv)
{
	Options options;
	for(int i = 1; i < argc; ++i)
	{
		std::string name(argv[i]);
		if(i + 1 >= argc) throw std::runtime_error("Missing value for " + name + ".");
		std::string value(argv[++i]);
		if(name == "--database") options.database = value;
		else if(name == "--output") options.output = value;
		else if(name == "--priors") options.priors = value;
		else if(name == "--input-identity") options.inputIdentity = value;
		else if(name == "--database-sha256") options.databaseSha256 = value;
		else if(name == "--horizontal-axes") options.horizontalAxes = value;
		else if(name == "--initial-x") options.initialX = parseFinite(value, "initial-x");
		else if(name == "--initial-y") options.initialY = parseFinite(value, "initial-y");
		else if(name == "--initial-yaw") options.initialYaw = parseFinite(value, "initial-yaw");
		else if(name == "--iterations") options.iterations = parseInteger(value, "iterations");
		else if(name == "--epsilon") options.epsilon = parseFinite(value, "epsilon");
		else throw std::runtime_error("Unknown argument " + name + ".");
	}
	if(options.database.empty() || options.output.empty() ||
		!isLowerHexSha256(options.inputIdentity) ||
		!isLowerHexSha256(options.databaseSha256))
	{
		throw std::runtime_error("--database, --output and lowercase SHA-256 input/database identities are required.");
	}
	if(options.epsilon < 0.0) throw std::runtime_error("epsilon cannot be negative.");
	if(options.horizontalAxes != "xy" && options.horizontalAxes != "xz") throw std::runtime_error("horizontal-axes must be xy or xz.");
	return options;
}

std::vector<Prior> loadPriors(const Options & options)
{
	std::vector<Prior> priors;
	if(options.priors.empty()) return priors;
	std::ifstream input(options.priors.c_str(), std::ios::binary);
	if(!input) throw std::runtime_error("Cannot open absolute-prior input.");
	std::string line;
	if(!std::getline(input, line) || line != "MarketScannerAbsoluteSE2Priors\t1\t" + options.inputIdentity)
	{
		throw std::runtime_error("Absolute-prior header or input identity is invalid.");
	}
	std::set<std::string> ids;
	while(std::getline(input, line))
	{
		if(line.empty()) continue;
		std::vector<std::string> fields = splitTabs(line);
		if(fields.size() != 7) throw std::runtime_error("Absolute-prior record must have seven fields.");
		if(fields[0].empty() || fields[1].empty() || !ids.insert(fields[0]).second)
		{
			throw std::runtime_error("Absolute-prior identifiers must be non-empty and unique.");
		}
		Prior prior;
		prior.id = fields[0];
		prior.kind = fields[1];
		prior.nodeId = parseInteger(fields[2], "prior node id");
		prior.x = parseFinite(fields[3], "prior x");
		prior.y = parseFinite(fields[4], "prior y");
		prior.yaw = parseFinite(fields[5], "prior yaw");
		prior.weight = parseFinite(fields[6], "prior weight");
		if(prior.weight <= 0.0 || prior.weight > 1000000.0) throw std::runtime_error("Absolute-prior weight is outside the safe range.");
		priors.push_back(prior);
	}
	return priors;
}

Transform projectTransform(const Transform & transform, const std::string & horizontalAxes)
{
	if(horizontalAxes == "xy")
	{
		return Transform(transform.x(), transform.y(), transform.theta());
	}
	// Match supermarket_2d_map.py's native-to-iOS convention:
	// ios(x,y,z)=(-native_y,native_z,-native_x), with the floor plane x/z.
	return Transform(-transform.y(), -transform.x(), std::atan2(-transform.r32(), transform.r22()));
}

Transform projectedMeasurement(
	const Transform & nativeFrom,
	const Transform & nativeMeasurement,
	const std::string & horizontalAxes)
{
	Transform projectedFrom = projectTransform(nativeFrom, horizontalAxes);
	Transform projectedEndpoint = projectTransform(nativeFrom * nativeMeasurement, horizontalAxes);
	return projectedFrom.inverse() * projectedEndpoint;
}

std::array<double, 9> planarInformation(
	const cv::Mat & matrix,
	const Transform & nativeFrom,
	const Transform & nativeMeasurement,
	const std::string & horizontalAxes)
{
	if(matrix.rows != 6 || matrix.cols != 6 || matrix.type() != CV_64FC1)
	{
		throw std::runtime_error("A relative Link information matrix is not 6x6 CV_64F.");
	}
	for(int row=0;row<6;++row) for(int column=0;column<6;++column)
		if(!std::isfinite(matrix.at<double>(row,column))) throw std::runtime_error("A relative Link information matrix is non-finite.");
	cv::Mat covariance;
	if(!cv::invert(matrix,covariance,cv::DECOMP_SVD)) throw std::runtime_error("A relative Link information matrix cannot be inverted.");
	cv::Mat jacobian=cv::Mat::zeros(3,6,CV_64FC1);
	const double step=1.0e-5;
	Transform base=projectedMeasurement(nativeFrom,nativeMeasurement,horizontalAxes);
	for(int axis=0;axis<6;++axis)
	{
		double delta[6]={0,0,0,0,0,0}; delta[axis]=step;
		Transform perturb(static_cast<float>(delta[0]),static_cast<float>(delta[1]),static_cast<float>(delta[2]),static_cast<float>(delta[3]),static_cast<float>(delta[4]),static_cast<float>(delta[5]));
		Transform shifted=projectedMeasurement(nativeFrom,nativeMeasurement*perturb,horizontalAxes);
		jacobian.at<double>(0,axis)=(shifted.x()-base.x())/step;
		jacobian.at<double>(1,axis)=(shifted.y()-base.y())/step;
		jacobian.at<double>(2,axis)=normalizeAngle(shifted.theta()-base.theta())/step;
	}
	cv::Mat planarCovariance=jacobian*covariance*jacobian.t();
	planarCovariance=(planarCovariance+planarCovariance.t())*0.5;
	planarCovariance+=cv::Mat::eye(3,3,CV_64FC1)*1.0e-12;
	cv::Mat projectedInformation;
	if(!cv::invert(planarCovariance,projectedInformation,cv::DECOMP_SVD)) throw std::runtime_error("Projected planar covariance cannot be inverted.");
	projectedInformation=(projectedInformation+projectedInformation.t())*0.5;
	cv::Mat eigenvalues;
	if(!cv::eigen(projectedInformation,eigenvalues) || eigenvalues.at<double>(2,0)<=1.0e-10)
		throw std::runtime_error("Projected planar information is not positive definite.");
	std::array<double, 9> result;
	for(int row=0;row<3;++row) for(int column=0;column<3;++column) result[row*3+column]=projectedInformation.at<double>(row,column);
	for(int row = 0; row < 3; ++row)
	{
		for(int column = row + 1; column < 3; ++column)
		{
			if(std::fabs(result[row*3+column] - result[column*3+row]) > 1.0e-8 * std::max(1.0, std::fabs(result[row*3+column])))
			{
				throw std::runtime_error("A relative Link planar information matrix is not symmetric.");
			}
		}
	}
	double minor1 = result[0];
	double minor2 = result[0]*result[4] - result[1]*result[3];
	double determinant = result[0]*(result[4]*result[8]-result[5]*result[7]) - result[1]*(result[3]*result[8]-result[5]*result[6]) + result[2]*(result[3]*result[7]-result[4]*result[6]);
	if(minor1 <= 0.0 || minor2 <= 0.0 || determinant <= 0.0)
	{
		throw std::runtime_error("A relative Link planar information matrix is not positive definite.");
	}
	return result;
}

std::string canonicalFactor(const std::string & id, const std::string & kind, const Link & link, const std::array<double,9> & information)
{
	std::ostringstream out;
	out << std::setprecision(17) << id << '\t' << kind << '\t' << link.from() << '\t' << link.to() << '\t'
		<< static_cast<double>(link.transform().x()) << '\t' << static_cast<double>(link.transform().y()) << '\t'
		<< static_cast<double>(link.transform().theta());
	for(size_t i = 0; i < information.size(); ++i) out << '\t' << information[i];
	out << '\n';
	return out.str();
}

std::array<double,3> residual(const Transform & from, const Transform & to, const Transform & measurement)
{
	Transform error = measurement.inverse() * (from.inverse() * to);
	return {{static_cast<double>(error.x()), static_cast<double>(error.y()), normalizeAngle(static_cast<double>(error.theta()))}};
}

double objective(const std::map<int,Transform> & poses, const std::vector<Factor> & factors)
{
	double total = 0.0;
	for(size_t i = 0; i < factors.size(); ++i)
	{
		const Factor & factor = factors[i];
		std::map<int,Transform>::const_iterator from = poses.find(factor.link.from());
		std::map<int,Transform>::const_iterator to = poses.find(factor.link.to());
		if(from == poses.end() || to == poses.end()) throw std::runtime_error("Factor endpoint is missing during objective evaluation.");
		std::array<double,3> e;
		if(factor.link.from() == factor.link.to())
		{
			Transform error = factor.link.transform().inverse() * from->second;
			e = {{static_cast<double>(error.x()), static_cast<double>(error.y()), normalizeAngle(static_cast<double>(error.theta()))}};
		}
		else e = residual(from->second, to->second, factor.link.transform());
		double weighted = 0.0;
		for(int row = 0; row < 3; ++row)
			for(int column = 0; column < 3; ++column)
				weighted += e[row] * factor.planarInformation[row*3+column] * e[column];
		if(!std::isfinite(weighted)) throw std::runtime_error("Factor objective became non-finite.");
		total += weighted;
	}
	return total;
}

bool acceptedRelativeType(Link::Type type)
{
	return type == Link::kNeighbor || type == Link::kNeighborMerged || type == Link::kGlobalClosure ||
		type == Link::kLocalSpaceClosure || type == Link::kLocalTimeClosure || type == Link::kUserClosure || type == Link::kVirtualClosure;
}

std::string factorKind(Link::Type type)
{
	if(type == Link::kNeighbor || type == Link::kNeighborMerged) return "relative_neighbor";
	return "relative_loop";
}

std::array<double,9> diagonalInformation(double weight)
{
	return {{weight,0.0,0.0,0.0,weight,0.0,0.0,0.0,weight}};
}

cv::Mat sixInformation(const std::array<double,9> & planar)
{
	cv::Mat matrix = cv::Mat::eye(6,6,CV_64FC1) * 1.0e-9;
	const int index[3] = {0,1,5};
	for(int row=0; row<3; ++row)
		for(int column=0; column<3; ++column)
			matrix.at<double>(index[row], index[column]) = planar[row*3+column];
	return matrix;
}

void writeResult(
	const Options & options,
	const std::string & databaseVersion,
	const std::map<int,Transform> & initial,
	const std::map<int,Transform> & optimized,
	const std::vector<Factor> & factors,
	const std::vector<std::string> & rejected,
	int rootId,
	double initialObjective,
	double finalObjective,
	double nativeFinalError,
	int iterationsDone,
	bool converged,
	bool hasAbsolutePriors)
{
	std::vector<double> translationResiduals;
	std::vector<double> yawResiduals;
	std::vector<std::string> downweighted;
	double maximumUpdate = 0.0;
	double maximumYawUpdate = 0.0;
	std::map<std::string,int> counts;
	for(size_t i=0; i<factors.size(); ++i)
	{
		++counts[factors[i].kind];
		if(factors[i].link.from() == factors[i].link.to()) continue;
		std::array<double,3> e = residual(optimized.at(factors[i].link.from()), optimized.at(factors[i].link.to()), factors[i].link.transform());
		double translation = std::hypot(e[0], e[1]);
		double yaw = std::fabs(e[2]);
		translationResiduals.push_back(translation);
		yawResiduals.push_back(yaw);
		if(factors[i].kind == "relative_loop" && (translation > 1.0 || yaw > 0.35)) downweighted.push_back(factors[i].id);
	}
	for(std::map<int,Transform>::const_iterator iter=optimized.begin(); iter!=optimized.end(); ++iter)
	{
		const Transform & before = initial.at(iter->first);
		maximumUpdate = std::max(maximumUpdate, static_cast<double>(before.getDistance(iter->second)));
		maximumYawUpdate = std::max(maximumYawUpdate, std::fabs(normalizeAngle(static_cast<double>(iter->second.theta()-before.theta()))));
	}
	std::sort(translationResiduals.begin(), translationResiduals.end());
	std::sort(yawResiduals.begin(), yawResiduals.end());
	double maxTranslation = translationResiduals.empty()?0.0:translationResiduals.back();
	double p95Translation = translationResiduals.empty()?0.0:translationResiduals[static_cast<size_t>(std::ceil(0.95*translationResiduals.size()))-1];
	double maxYaw = yawResiduals.empty()?0.0:yawResiduals.back();
	double p95Yaw = yawResiduals.empty()?0.0:yawResiduals[static_cast<size_t>(std::ceil(0.95*yawResiduals.size()))-1];

	std::vector<Factor> sortedFactors = factors;
	std::sort(sortedFactors.begin(), sortedFactors.end(), [](const Factor & a, const Factor & b){return a.id < b.id;});
	Sha256 digest;
	for(size_t i=0; i<sortedFactors.size(); ++i) digest.update(sortedFactors[i].canonical);
	std::string factorSetSha256 = digest.finish();

	std::ofstream out(options.output.c_str(), std::ios::binary | std::ios::trunc);
	if(!out) throw std::runtime_error("Cannot create factor-graph result.");
	out << std::setprecision(17);
	out << "{\n  \"format\":\"" << kFormat << "\",\n  \"version\":" << kVersion
		<< ",\n  \"solver\":\"rtabmap_g2o_slam2d\",\n  \"full_factor_graph\":" << (converged?"true":"false")
		<< ",\n  \"published_capable\":" << (converged?"true":"false")
		<< ",\n  \"input_identity_id\":\"" << jsonEscape(options.inputIdentity) << "\""
		<< ",\n  \"optimized_database_sha256\":\"" << jsonEscape(options.databaseSha256) << "\""
		<< ",\n  \"database_version\":\"" << jsonEscape(databaseVersion) << "\""
		<< ",\n  \"factor_set_sha256\":\"" << factorSetSha256 << "\""
		<< ",\n  \"node_count\":" << optimized.size() << ",\n  \"factor_count\":" << factors.size()
		<< ",\n  \"root_node_id\":" << rootId
		<< ",\n  \"gauge_mode\":\"" << (hasAbsolutePriors?"absolute_priors":"fixed_root") << "\""
		<< ",\n  \"graph_connected\":true"
		<< ",\n  \"initial_objective\":" << initialObjective
		<< ",\n  \"final_objective\":" << finalObjective
		<< ",\n  \"native_final_error\":" << nativeFinalError
		<< ",\n  \"iterations_done\":" << iterationsDone
		<< ",\n  \"converged\":" << (converged?"true":"false")
		<< ",\n  \"maximum_pose_update_m\":" << maximumUpdate
		<< ",\n  \"maximum_pose_update_yaw_deg\":" << maximumYawUpdate*180.0/M_PI
		<< ",\n  \"maximum_relative_edge_translation_residual_m\":" << maxTranslation
		<< ",\n  \"p95_relative_edge_translation_residual_m\":" << p95Translation
		<< ",\n  \"maximum_relative_edge_yaw_residual_deg\":" << maxYaw*180.0/M_PI
		<< ",\n  \"p95_relative_edge_yaw_residual_deg\":" << p95Yaw*180.0/M_PI;
	out << ",\n  \"factor_counts_by_type\":{";
	bool first = true;
	for(std::map<std::string,int>::const_iterator iter=counts.begin(); iter!=counts.end(); ++iter)
	{
		if(!first) out << ','; first=false;
		out << "\"" << jsonEscape(iter->first) << "\":" << iter->second;
	}
	out << "},\n  \"downweighted_factor_ids\":[";
	for(size_t i=0;i<downweighted.size();++i){if(i)out<<',';out<<"\""<<jsonEscape(downweighted[i])<<"\"";}
	out << "],\n  \"rejected_factor_ids\":[";
	for(size_t i=0;i<rejected.size();++i){if(i)out<<',';out<<"\""<<jsonEscape(rejected[i])<<"\"";}
	out << "],\n  \"factors\":[\n";
	for(size_t i=0;i<sortedFactors.size();++i)
	{
		const Factor & f=sortedFactors[i];
		out << "    {\"id\":\""<<jsonEscape(f.id)<<"\",\"kind\":\""<<jsonEscape(f.kind)
			<<"\",\"from_node_id\":"<<f.link.from()<<",\"to_node_id\":"<<f.link.to()
			<<",\"measurement\":["<<static_cast<double>(f.link.transform().x())<<','<<static_cast<double>(f.link.transform().y())<<','<<static_cast<double>(f.link.transform().theta())<<"]"
			<<",\"planar_information\":[";
		for(size_t j=0;j<f.planarInformation.size();++j){if(j)out<<',';out<<f.planarInformation[j];}
		out << "],\"canonical\":\""<<jsonEscape(f.canonical)<<"\"}"<<(i+1<sortedFactors.size()?",":"")<<"\n";
	}
	out << "  ],\n  \"poses\":[\n";
	size_t poseIndex=0;
	for(std::map<int,Transform>::const_iterator iter=optimized.begin();iter!=optimized.end();++iter,++poseIndex)
	{
		out << "    {\"node_id\":"<<iter->first<<",\"x\":"<<static_cast<double>(iter->second.x())<<",\"y\":"<<static_cast<double>(iter->second.y())<<",\"yaw\":"<<static_cast<double>(iter->second.theta())<<"}"<<(poseIndex+1<optimized.size()?",":"")<<"\n";
	}
	out << "  ]\n}\n";
	out.flush();
	if(!out) throw std::runtime_error("Failed writing factor-graph result.");
}

} // namespace

int main(int argc, char ** argv)
{
	try
	{
		if(argc == 2 && std::string(argv[1]) == "--version")
		{
#ifdef MARKETSCANNER_GIT_SHA
			std::cout << "rtabmap-prior-map-factor-graph " << RTABMAP_VERSION << " marketscanner_git_sha=" << MARKETSCANNER_GIT_SHA << std::endl;
#else
			std::cout << "rtabmap-prior-map-factor-graph " << RTABMAP_VERSION << " marketscanner_git_sha=untracked-build" << std::endl;
#endif
			return 0;
		}
		ULogger::setType(ULogger::kTypeConsole);
		ULogger::setLevel(ULogger::kWarning);
		Options options = parseOptions(argc, argv);
		std::shared_ptr<DBDriver> driver(DBDriver::create());
		if(!driver.get() || !driver->openConnection(options.database, false, true))
		{
			throw std::runtime_error("Cannot open optimized database read-only.");
		}
		std::string databaseVersion = driver->getDatabaseVersion();
		std::map<int,Transform> odomPoses;
		driver->getAllOdomPoses(odomPoses, true, true);
		std::map<int,Transform> savedPoses = driver->loadOptimizedPoses();
		std::multimap<int,Link> databaseLinks;
		driver->getAllLinks(databaseLinks, true, false);
		driver->closeConnection(false);
		if(odomPoses.empty()) throw std::runtime_error("Optimized database contains no odometry poses.");
		std::map<int,Transform> poses = savedPoses.empty()?odomPoses:savedPoses;
		if(poses.size()!=odomPoses.size()) throw std::runtime_error("Saved optimized pose inventory does not match odometry nodes.");
		for(std::map<int,Transform>::const_iterator iter=odomPoses.begin();iter!=odomPoses.end();++iter)
		{
			if(iter->first<=0 || poses.find(iter->first)==poses.end() || !finiteTransform(poses.at(iter->first)))
				throw std::runtime_error("Pose inventory contains a missing, non-positive or non-finite node.");
		}

		std::map<int,Transform> nativePoses=poses;
		for(std::map<int,Transform>::iterator iter=poses.begin();iter!=poses.end();++iter)
		{
			iter->second = projectTransform(iter->second, options.horizontalAxes);
		}
		int rootId = poses.begin()->first;
		Transform firstPose = poses.begin()->second;
		Transform target(static_cast<float>(options.initialX), static_cast<float>(options.initialY), static_cast<float>(options.initialYaw));
		Transform alignment = target * firstPose.inverse();
		for(std::map<int,Transform>::iterator iter=poses.begin();iter!=poses.end();++iter) iter->second = alignment * iter->second;
		std::map<int,Transform> initial = poses;

		std::vector<Factor> factors;
		std::vector<std::string> rejected;
		std::multimap<int,Link> optimizerLinks;
		std::set<std::tuple<int,int,int> > duplicates;
		std::map<int,std::set<int> > adjacency;
		for(std::multimap<int,Link>::const_iterator iter=databaseLinks.begin();iter!=databaseLinks.end();++iter)
		{
			const Link & link=iter->second;
			if(!acceptedRelativeType(link.type()))
			{
				rejected.push_back("db:"+Link::typeName(link.type())+":"+std::to_string(link.from())+":"+std::to_string(link.to()));
				continue;
			}
			if(link.from()<=0 || link.to()<=0 || link.from()==link.to() || poses.find(link.from())==poses.end() || poses.find(link.to())==poses.end())
				throw std::runtime_error("A required relative Link has invalid endpoints.");
			if(!finiteTransform(link.transform())) throw std::runtime_error("A required relative Link transform is non-finite or singular.");
			std::tuple<int,int,int> key(std::min(link.from(),link.to()),std::max(link.from(),link.to()),static_cast<int>(link.type()));
			if(!duplicates.insert(key).second) continue;
			std::array<double,9> information = planarInformation(link.infMatrix(), nativePoses.at(link.from()), link.transform(), options.horizontalAxes);
			Transform measurement=projectedMeasurement(nativePoses.at(link.from()),link.transform(),options.horizontalAxes);
			Link projectedLink(link.from(), link.to(), link.type(), measurement, sixInformation(information));
			Factor factor;
			factor.id="db:"+Link::typeName(link.type())+":"+std::to_string(link.from())+":"+std::to_string(link.to());
			factor.kind=factorKind(link.type());
			factor.link=projectedLink;
			factor.planarInformation=information;
			factor.canonical=canonicalFactor(factor.id,factor.kind,factor.link,factor.planarInformation);
			factors.push_back(factor);
			optimizerLinks.insert(std::make_pair(projectedLink.from(),projectedLink));
			adjacency[link.from()].insert(link.to()); adjacency[link.to()].insert(link.from());
		}
		if(factors.empty()) throw std::runtime_error("The graph contains no accepted relative factors.");
		std::set<int> visited; std::queue<int> pending; pending.push(rootId); visited.insert(rootId);
		while(!pending.empty()){int node=pending.front();pending.pop();for(std::set<int>::const_iterator n=adjacency[node].begin();n!=adjacency[node].end();++n)if(visited.insert(*n).second)pending.push(*n);}
		if(visited.size()!=poses.size()) throw std::runtime_error("Relative factor graph is disconnected.");

		std::vector<Prior> priors=loadPriors(options);
		// A pure relative graph uses rootId as its fixed gauge. If absolute
		// priors are present they define the map frame and RTAB-Map deliberately
		// releases the fixed root so those priors can correct the whole graph.
		const bool hasAbsolutePriors = !priors.empty();
		for(size_t i=0;i<priors.size();++i)
		{
			const Prior & prior=priors[i];
			if(poses.find(prior.nodeId)==poses.end()) throw std::runtime_error("Absolute prior references a missing node.");
			std::array<double,9> information=diagonalInformation(prior.weight);
			cv::Mat full=sixInformation(information);
			Link link(prior.nodeId,prior.nodeId,Link::kPosePrior,Transform(static_cast<float>(prior.x),static_cast<float>(prior.y),static_cast<float>(prior.yaw)),full);
			Factor factor; factor.id="prior:"+prior.id; factor.kind=prior.kind; factor.link=link; factor.planarInformation=information;
			factor.canonical=canonicalFactor(factor.id,factor.kind,factor.link,factor.planarInformation);
			factors.push_back(factor); optimizerLinks.insert(std::make_pair(link.from(),link));
		}

		ParametersMap parameters;
		parameters.insert(ParametersPair(Parameters::kOptimizerStrategy(),"1"));
		parameters.insert(ParametersPair(Parameters::kOptimizerIterations(),std::to_string(options.iterations)));
		parameters.insert(ParametersPair(Parameters::kOptimizerEpsilon(),std::to_string(options.epsilon)));
		parameters.insert(ParametersPair(Parameters::kOptimizerRobust(),"true"));
		parameters.insert(ParametersPair(Parameters::kOptimizerPriorsIgnored(),"false"));
		parameters.insert(ParametersPair(Parameters::kOptimizerLandmarksIgnored(),"true"));
		parameters.insert(ParametersPair(Parameters::kRegForce3DoF(),"true"));
		parameters.insert(ParametersPair(Parameters::kg2oRobustKernelDelta(),"8"));
		parameters.insert(ParametersPair(Parameters::kg2oSolver(),"3"));
		std::shared_ptr<Optimizer> optimizer(Optimizer::create(Optimizer::kTypeG2O,parameters));
		if(!optimizer.get() || !Optimizer::isAvailable(Optimizer::kTypeG2O)) throw std::runtime_error("RTAB-Map g2o optimizer is unavailable.");
		optimizer->setSlam2d(true); optimizer->setPriorsIgnored(false); optimizer->setLandmarksIgnored(true); optimizer->setIterations(options.iterations); optimizer->setEpsilon(options.epsilon); optimizer->setRobust(true);
		double initialObjective=objective(initial,factors);
		double nativeFinalError=std::numeric_limits<double>::quiet_NaN(); int iterationsDone=0;
		std::map<int,Transform> optimized=optimizer->optimize(rootId,poses,optimizerLinks,0,&nativeFinalError,&iterationsDone);
		if(optimized.size()!=poses.size()) throw std::runtime_error("Native optimizer returned an incomplete node inventory.");
		for(std::map<int,Transform>::const_iterator iter=optimized.begin();iter!=optimized.end();++iter) if(!finiteTransform(iter->second)) throw std::runtime_error("Native optimizer returned a non-finite pose.");
		double finalObjective=objective(optimized,factors);
		bool converged=iterationsDone>0 && std::isfinite(nativeFinalError) && std::isfinite(finalObjective) && finalObjective<=initialObjective+std::max(1.0e-8,std::fabs(initialObjective)*1.0e-7);
		writeResult(options,databaseVersion,initial,optimized,factors,rejected,rootId,initialObjective,finalObjective,nativeFinalError,iterationsDone,converged,hasAbsolutePriors);
		return converged?0:3;
	}
	catch(const std::exception & error)
	{
		std::cerr << "FACTOR_GRAPH_ERROR: " << error.what() << std::endl;
		return 2;
	}
}
