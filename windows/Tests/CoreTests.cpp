#include "Protocol.h"
#include "Translation.h"
#include <iostream>
#include <stdexcept>
using namespace sailking;
void require(bool result,const char* message){if(!result)throw std::runtime_error(message);}
int main(){
    try{
        Request r;require(valid(r),"valid request rejected");r.protocol=2;require(!valid(r),"unsupported version accepted");r.protocol=version;
        std::fill(std::begin(r.text),std::end(r.text),u'x');require(!valid(r),"unterminated input accepted");
        char16_t small[3];require(copy(small,u"你好"),"UTF-16 copy failed");require(!copy(small,u"你好啊")&&small[0]==0,"truncated output accepted");
        require(entitiesIntact("AB-123 https://example.com user@example.com","AB-123 https://example.com user@example.com"),"protected identifiers rejected");
        require(!entitiesIntact("AB-123 AB-123","AB-123"),"duplicate identifier lost");
        require(!entitiesIntact("Order AB-123","Order AB-124"),"changed order accepted");
        auto p=prompt("Gift","de","en");require(p.find("German text")!=std::string::npos&&p.find("English")!=std::string::npos,"manual source ignored");
        bool rejected=false;try{prompt("test","auto","invented\nrole");}catch(...){rejected=true;}require(rejected,"unsafe target accepted");
        std::cout<<"Windows wire protocol and protected translation tests passed\n";return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 1;}
}
